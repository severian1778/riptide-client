defmodule RiptideExecutor.TradeEngine do
  @moduledoc """
  Turns a ladder prediction into a managed trade.

  The narrowest module in the executor, deliberately: it is the
  single decision point between "the feed said something" and "real
  money moves". Everything below it (TradeSupervisor, ManagedTrade)
  assumes execution is authorized; everything above it (Feed) only
  routes. TradeEngine decides WHETHER a ladder becomes a trade, on
  WHAT venue, and at WHAT capital base.

  ## LADDERS ONLY

  The only tradeable event is a full multi-tier ladder prediction —
  a map with a non-empty "tiers" list. The legacy flat "prediction"
  event is refused at the clause level (`execute/1`'s second clause)
  and logged, never traded. This is the executor-side half of the
  contract whose other half is Feed's handler, which also drops flat
  predictions; both layers must agree for a trade to exist.

  ## The safety gate — DRY_RUN

  DRY_RUN=true (the DEFAULT) is the safe state: the ladder is logged
  in full and its ledger record is opened-and-immediately-closed as
  :dry_run. This is not a no-op — recording the decision keeps the
  track record honest about what the system WOULD have traded during
  dry-run periods, while guaranteeing zero venue contact.

  DRY_RUN=false sends real orders. The flag is read on EVERY
  execution (not cached at boot), so flipping it in the running
  node's environment takes effect on the next ladder without a
  restart.

  ## Venue and capital selection

    - VENUE env ("hyperliquid" | "kucoin", default hyperliquid)
      selects the Venue adapter. venue_module/0 is THE one resolution
      point for the module name — Reconcile duplicates the env read
      with its own case clause; if a third venue is ever added, BOTH
      sites must change. (Deliberate duplication of a two-way switch:
      an indirection module for one if-expression is not worth the
      risk of the two call sites diverging in behavior.)
    - BANKROLL_USD (default 10_000.0) is the notional capital base
      passed to the walk. It is the NUMBER the Kelly sizing divides
      against — it is NOT read from the venue balance. The fund's
      model is fixed-fractional risk on a declared bankroll, not
      whatever the account happens to hold; account state is
      reconciliation's business, not sizing's.

  ## Failure posture

  Every downstream refusal is information, never a crash: an
  already-running duplicate logs a warning (the dedupe triple did
  its job), a genuine start failure logs an error and the ladder is
  simply not traded. Nothing here retries — the feed's at-least-once
  delivery means a genuinely dropped ladder will be re-delivered and
  re-decided anyway.
  """

  require Logger

  alias RiptideExecutor.{Ledger, TradeSupervisor}

  @doc """
  The tradeable entry point: a ladder payload with a "tiers" list.

  Flow:
    1. Log the ladder in full (the LADDER ACCEPTED banner — the
       permanent record of what the decision saw, readable in logs
       long after DETS rotates).
    2. DRY_RUN=true → record-and-close as :dry_run. Zero orders.
    3. DRY_RUN=false → build the ManagedTrade args tuple
       {venue_module, oracle_module, key, ladder, bankroll} and hand
       it to TradeSupervisor. The dedupe key
       {symbol, market_type, anchor_ts} is built here and travels
       with the trade for its whole life — ledger record, registry
       name, supervisor child id are all keyed on this triple.

  Note the key uses the BROADCAST anchor_ts string, not a parsed
  DateTime — every consumer (Ledger, Registry, supervisor id) keys
  on the identical wire value, so no parsing round-trip can make two
  consumers disagree about identity.
  """
  def execute(%{"tiers" => tiers} = ladder) when is_list(tiers) do
    log_ladder(ladder)

    if dry_run?() do
      key = {ladder["symbol"], ladder["market_type"], ladder["anchor_ts"]}

      Ledger.close_trade(key, %{
        total_r: 0.0,
        ending: :dry_run,
        closed_at: DateTime.utc_now(),
        note: "DRY_RUN=true — logged, never traded"
      })

      Logger.info("TradeEngine: DRY_RUN=true — ladder logged, closed as :dry_run")
    else
      bankroll = num("BANKROLL_USD", 10_000.0)
      key = {ladder["symbol"], ladder["market_type"], ladder["anchor_ts"]}
      args = {venue_module(), RiptideExecutor.Oracle, key, ladder, bankroll}

      case TradeSupervisor.start_trade(args) do
        {:ok, pid} ->
          Logger.info(
            "TradeEngine: ManagedTrade queued #{inspect(pid)} on #{venue_name()} for #{inspect(key)}"
          )

        {:error, {:already_started, pid}} ->
          # The dedupe triple caught a same-session duplicate delivery
          # before the walk even started — the at-least-once feed
          # working as designed. Benign.
          Logger.warning("TradeEngine: trade already running #{inspect(pid)}")

        {:error, reason} ->
          # Genuine start failure — ladder is NOT traded. No retry:
          # the feed re-delivers and the decision re-runs.
          Logger.error("TradeEngine: failed to start ManagedTrade: #{inspect(reason)}")
      end
    end
  end

  def execute(other) do
    Logger.warning("TradeEngine: refusing non-ladder payload — #{inspect(other)}")
  end

  @doc """
  THE one resolution point for the venue adapter module.
  .env: VENUE=hyperliquid or VENUE=kucoin; anything else (including
  unset) defaults to Hyperliquid.

  CAUTION: Reconcile reads the same env with its own copy of this
  case clause — keep both in sync when adding a venue. Public (not
  defp) so diagnostic sessions can ask "which adapter is live"
  without duplicating the env read a third time.
  """
  def venue_module do
    case venue_name() do
      "kucoin" -> RiptideExecutor.Kucoin.Venue
      _ -> RiptideExecutor.Hyperliquid.Venue
    end
  end

  @doc "The VENUE env name, defaulting to \"hyperliquid\"."
  def venue_name, do: System.get_env("VENUE", "hyperliquid")

  # The full-ladder log line. This is the forensic record of the
  # decision input: direction, entry price, anchor, and every tier's
  # geometry. When auditing a closed trade months later, THIS block
  # in the logs is the ground truth of what was broadcast — the
  # ledger's copy of the ladder lives in DETS and can be inspected,
  # but the log line survives even a corrupted ledger file.
  defp log_ladder(ladder) do
    tier_lines =
      Enum.map_join(ladder["tiers"], "\n", fn t ->
        "  #{t["horizon"]}: SL #{t["sl_pct"]}%  TP2 #{t["tp2_pct"]}%  hold #{t["bars"]}m  E[R] #{t["r_mean"]}  Kelly #{t["kelly_fraction"]}"
      end)

    Logger.info("""
    ═══ LADDER ACCEPTED ═══
    #{ladder["direction"]} #{ladder["market_type"]} @ $#{ladder["entry_price"]}
    anchor: #{ladder["anchor_ts"]}
    risk anchor: #{ladder["risk_anchor_horizon"]}  Kelly: #{ladder["kelly_fraction"]}
    #{tier_lines}
    ═════════════════════════════════
    """)
  end

  # Read per-call, never cached: flipping DRY_RUN in the environment
  # of a running node takes effect on the next ladder. Default true —
  # the system must be SAFE by absence of configuration.
  defp dry_run?, do: System.get_env("DRY_RUN", "true") == "true"

  # Float env parser with fallback. An unparseable value silently
  # uses the default rather than raising: a typo'd BANKROLL_USD must
  # degrade to the default bankroll, never crash the feed's message
  # handler.
  defp num(name, default) do
    case System.get_env(name) do
      nil ->
        default

      v ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> default
        end
    end
  end
end

