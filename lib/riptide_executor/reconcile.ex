defmodule RiptideExecutor.Reconcile do
  @moduledoc """
  Boot-time and on-demand reconciliation between the Ledger, the live
  ManagedTrade processes, and the venue's actual positions.

  ## Why this exists

  The executor holds state in THREE places that can disagree:
  the DETS ledger (what SHOULD be open), the process registry
  (what IS being managed), and the venue (what money is actually
  at risk). Crashes, restarts, and partial failures can knock the
  three out of sync — the 2026-10-28 duplicate-nonce crash did
  exactly that: process dead, ledger open, position live with no
  stop. Reconcile is the tool that classifies and repairs that
  divergence, and its classifications encode the fund's response
  policy:

    - HEALTHY — ledger open AND a live ManagedTrade process holds
      the key. The walk owns it; nothing to do.
    - GHOST — ledger open, NO process, and the venue holds NO
      position. Nothing real is at risk; the record is bookkeeping
      residue (crashed before entry, or closed on the venue while
      the ledger write was lost). Auto-closed in the ledger with
      ending :orphan and total_r 0.0 — zero money moved, zero
      profit claimed.
    - ORPHAN — ledger open, NO process, but the venue DOES hold a
      position. Real money with no state machine managing it: no
      ratchet, no stop replacement, no exit logic. Reconcile NEVER
      auto-closes these — closing means placing real orders, and
      the human decides size/level/timing. They are reported
      LOUDLY (Logger.error) and returned in the summary for the
      caller to act on.

  ## Known limitation — the position check is ACCOUNT-level

  venue_position?/1 asks "does the account hold ANY position", not
  "does a position cover THIS trade". Consequences:

    - One orphan makes every simultaneously-unmanaged trade classify
      as an orphan (conservative direction — surfaces work, never
      hides it).
    - A ghost can be misclassified as an orphan if an UNRELATED
      position exists on the account (e.g. a manual hedge). When
      the orphan report names a key you don't recognize as having
      size, check the venue manually before acting — the
      classification is a filter, not a verdict.

  This is deliberate until per-trade attribution (matching position
  entry timestamps/prices against ledger fills) is built.

  ## The fail-safe direction

  venue_position?/1 treats a venue ERROR as "position may exist"
  (true). An unreachable exchange must never green-light closing
  ledger records — a ghost closed while the venue was actually
  holding its position would erase the last record of real money.
  Every uncertain case resolves toward the louder, safer outcome.

  ## When to run it

  - Manually, any time — Status.print's 💀 lines point here.
  - After every executor restart, before trusting the books.
  - It is NOT wired into Application boot today: boot-time runs
    were deliberately deferred so a cold start never auto-mutates
    the ledger before a human has looked. Run Reconcile.run/0 by
    hand as the first command after any restart.
  """

  require Logger

  alias RiptideExecutor.{Ledger, ManagedTrade}

  @doc """
  Reconciles all open ledger trades.

  Returns:

      %{
        ghosts_closed: n,     # count auto-closed as :orphan (0R)
        orphans: [keys],      # REAL positions, unmanaged — ACT
        healthy: [keys]      # live walks, no action needed
      }

  Idempotent: running it twice in a row converges (the first run
  closes ghosts, so the second run sees only healthy + orphans).
  Side effects: ledger writes for ghosts only; log lines for
  everything.
  """
  def run do
    venue = venue_module()

    results =
      Ledger.open_trades()
      |> Enum.map(fn key ->
        cond do
          # Live process holds the walk — trust it, move on. This
          # check is cheap (registry lookup + GenServer call) and
          # takes priority: a running walk makes the venue question
          # moot, since the walk itself is managing whatever exists.
          running?(key) ->
            {:healthy, key}

          # No process + venue holds SOMETHING → orphan. Loud, never
          # auto-closed. See moduledoc for the account-level caveat.
          venue_position?(venue) ->
            {:orphan, key}

          # No process + confirmed flat (or venue error, which also
          # lands here as per the fail-safe — no: errors map to
          # true above, so reaching this clause means the venue
          # CONFIRMED no positions) → ghost. Safe to close the
          # record: nothing is at risk anywhere.
          true ->
            Ledger.close_trade(key, %{
              total_r: 0.0,
              ending: :orphan,
              closed_at: DateTime.utc_now(),
              note: "no live process, no venue position — bookkeeping ghost"
            })

            {:ghost, key}
        end
      end)

    summary = %{
      ghosts_closed: results |> Enum.count(&match?({:ghost, _}, &1)),
      orphans: results |> Enum.filter(&match?({:orphan, _}, &1)) |> Enum.map(&elem(&1, 1)),
      healthy: results |> Enum.filter(&match?({:healthy, _}, &1)) |> Enum.map(&elem(&1, 1))
    }

    # Orphans are an INCIDENT, not an info line: real money, no
    # manager. error-level so it survives log-level filtering and
    # any alerting wired to the logger.
    unless summary.orphans == [] do
      Logger.error("Reconcile: ORPHANED venue positions with no managing process: #{inspect(summary.orphans)}")
    end

    Logger.info(
      "Reconcile: #{summary.ghosts_closed} ghosts closed, #{length(summary.healthy)} healthy, #{length(summary.orphans)} orphans"
    )

    summary
  end

  # A trade is "running" iff ManagedTrade.state/1 returns :ok —
  # the same call Status uses, with the same exit-catching inside
  # (a trade dying mid-call reads as an error, i.e. not running,
  # never a crash of Reconcile itself).
  defp running?(key) do
    case ManagedTrade.state(key) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ACCOUNT-level check, not per-trade (see moduledoc). Any position
  # at all → true. A venue ERROR also → true: fail SAFE. The only
  # path to false is an explicit {:ok, []} — the exchange said,
  # successfully, "you hold nothing".
  defp venue_position?(venue) do
    case venue.positions() do
      {:ok, []} -> false
      {:ok, _} -> true
      # Venue unreachable — fail SAFE: never close a ledger trade
      # while we can't confirm the exchange is flat.
      _ -> true
    end
  end

  # Same env read + case clause as TradeEngine.venue_module/0 —
  # duplicated DELIBERATELY for a two-way switch (see TradeEngine's
  # moduledoc); keep both in sync when adding a venue.
  defp venue_module do
    case System.get_env("VENUE", "hyperliquid") do
      "kucoin" -> RiptideExecutor.Kucoin.Venue
      _ -> RiptideExecutor.Hyperliquid.Venue
    end
  end
end

