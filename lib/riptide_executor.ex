defmodule RiptideExecutor do
  @moduledoc """
  The operator's front door — short commands for managing the system
  from IEx, so nobody has to remember the long module paths.

  Start with `help/0`. It prints the menu. Every command here either
  READS (safe, run anytime) or is clearly marked as placing orders
  (used only to clean up after an incident).

  Tip: add `alias RiptideExecutor, as: R` once (see .iex.exs) and
  every command becomes `R.status()`, `R.track()`, `R.flatten(key)`.
  """

  alias RiptideExecutor.{
    Ledger,
    ManagedTrade,
    MarketFeed,
    Reconcile,
    Status,
    TrackRecord,
    TradeEngine
  }

  # ══════════════════════════════════════════════════════════
  # The menu
  # ══════════════════════════════════════════════════════════

  @doc "Print the command menu. Start here."
  def help do
    IO.puts("""

    ═══ RIPTIDE EXECUTOR — OPERATOR COMMANDS ═══

    READING (safe, run anytime)
      status()          live dashboard — heartbeat + open trades
      track()           the scoreboard — all closed trades, R and $
      balance()         exchange account balance
      positions()       what the exchange actually holds
      oracle()          is the per-minute price feed alive?
      keys()            every trade ever recorded
      open()            trades whose books still say OPEN
      trade(key)        one trade's full record
      fills(key)        one trade's fills, in order
      log(key)          one trade's play-by-play (read after anything weird)
      state(key)        the live state of a running trade
      testnet?()        are we on fake money right now?

    FIXING (run after any restart or crash)
      reconcile()       books vs processes vs exchange — fixes ghosts,
                        shouts about orphans

    EMERGENCY (places REAL orders — incident cleanup only)
      flatten(key)      market-out of a trade's remaining position AND
                        correct the books automatically
      protect(key, px)  place a manual stop at px on a trade's position

    ═══════════════════════════════════════════
    """)

    :ok
  end

  # ══════════════════════════════════════════════════════════
  # Reading
  # ══════════════════════════════════════════════════════════

  @doc "The live dashboard."
  def status, do: Status.print()

  @doc "The scoreboard."
  def track, do: TrackRecord.print()

  @doc "Exchange account balance (uses whatever VENUE is configured)."
  def balance do
    case TradeEngine.venue_module().balance() do
      {:ok, b} -> IO.inspect(b, label: "Balance")
      e -> IO.puts("🛑 balance error: #{inspect(e)}")
    end

    :ok
  end

  @doc "What the exchange actually holds right now."
  def positions do
    case TradeEngine.venue_module().positions() do
      {:ok, []} -> IO.puts("✨ flat — no open positions")
      {:ok, p} -> IO.inspect(p, label: "Positions (#{length(p)})")
      e -> IO.puts("🛑 positions error: #{inspect(e)}")
    end

    :ok
  end

  @doc "Per-minute price feed health."
  def oracle, do: IO.inspect(MarketFeed.status())

  @doc "Every trade ever recorded."
  def keys, do: Ledger.trade_keys()

  @doc "Trades whose books still say OPEN."
  def open, do: Ledger.open_trades()

  @doc "One trade's full record."
  def trade(key), do: IO.inspect(Ledger.get_trade(key))

  @doc "One trade's fills, in order."
  def fills(key), do: IO.inspect(Ledger.fills(key), label: "Fills")

  @doc "One trade's play-by-play. Read this first after anything weird."
  def log(key), do: IO.inspect(Ledger.event_log(key), label: "Event log")

  @doc "The live state of a running trade."
  def state(key), do: IO.inspect(ManagedTrade.state(key))

  @doc "Are we pointed at testnet (fake money)?"
  def testnet?, do: IO.inspect(RiptideExecutor.Hyperliquid.Client.testnet?())

  # ══════════════════════════════════════════════════════════
  # Fixing
  # ══════════════════════════════════════════════════════════

  @doc "Books vs processes vs exchange. Run after ANY restart or crash."
  def reconcile, do: Reconcile.run()

  # ══════════════════════════════════════════════════════════
  # Emergency — these place REAL orders
  # ══════════════════════════════════════════════════════════

  @doc """
  Market-out of a trade's remaining position and fix the books.

  Only for incidents: the walk process died and the position needs
  human hands. Does three things in order:

    1. Reads the live walk state for the remaining size and infers
       the trade's direction (stop below entry = long).
    2. Sends a reduce-only market order on the venue.
    3. Closes the ledger record with the REAL R: banked R from the
       journal plus the exit R of what was just flattened.

  The walk's own books and the exchange stay consistent — no manual
  Ledger surgery needed afterwards.
  """
  def flatten(key) do
    unless System.get_env("DRY_RUN", "true") == "false" do
      IO.puts("⚠️  DRY_RUN=true — this still sends a REAL order (it bypasses the dry run).")
    end

    case ManagedTrade.state(key) do
      {:ok, %{phase: :walking, pos: pos, entry: entry, stop: stop}} when pos > 0.0 ->
        do_flatten(key, pos, entry, stop)

      {:ok, %{phase: :awaiting}} ->
        IO.puts("Trade never entered — no position to flatten. Closing books as :dry_run.")
        Ledger.close_trade(key, %{
          total_r: 0.0,
          ending: :dry_run,
          closed_at: DateTime.utc_now(),
          note: "flattened: never entered"
        })

      {:ok, %{phase: :initializing}} ->
        IO.puts("Trade still initializing — wait a few seconds and retry.")

      _ ->
        IO.puts("""
        🛑 No live process for #{inspect(key)}.
        The position (if any) must be flattened by hand:
          Venue.print_positions()   — see what's there
          Venue.place_market(%{side: :sell, qty: X, reduce_only: true, tag: :exit})
        Then close the books: Ledger.close_trade(key, %{...}).
        """)
    end

    :ok
  end

  defp do_flatten(key, pos, entry, stop) do
    # Direction from geometry: a long's stop sits BELOW entry.
    dir = if stop <= entry, do: 1, else: -1
    side = if dir == 1, do: :sell, else: :buy

    IO.puts(">>> Flattening #{pos} BTC (#{side} on #{TradeEngine.venue_name()})...")

    case TradeEngine.venue_module().place_market(%{
           side: side,
           qty: pos,
           reduce_only: true,
           tag: :exit
         }) do
      {:ok, ref} ->
        fill =
          case TradeEngine.venue_module().order_status(ref) do
            {:ok, %{"fill_price" => p}} when is_number(p) and p > 0.0 -> p
            _ -> entry
          end

        IO.puts(">>> Filled at $#{Float.round(fill, 2)}. Fixing the books...")

        # Rebuild the R exactly as the walk would have booked it:
        # banked R from the journal + exit R on what we just sold.
        trade = Ledger.get_trade(key) || %{}

        risk =
          case trade[:pred] do
            %{"tiers" => tiers} when is_list(tiers) ->
              tier1 = tiers |> Enum.sort_by(& &1["bars"]) |> hd()
              (trade[:entry] || entry) * tier1["sl_pct"] / 100.0

            _ ->
              (trade[:capital_risked] && trade[:entry]) || entry * 0.01
          end

        init_qty =
          case Ledger.fills(key) do
            [%{qty: q} | _] -> q
            _ -> pos
          end

        banked =
          Ledger.event_log(key)
          |> Enum.filter(fn {e, _} -> e == :bank end)
          |> Enum.map(fn {_, d} -> d[:r] || 0.0 end)
          |> Enum.sum()

        r_exit = pos / max(init_qty, pos) * dir * (fill - entry) / max(risk, 1.0e-9)
        total = banked + r_exit

        Ledger.record_fill(key, :stop_exit, %{price: fill, qty: pos})

        Ledger.close_trade(key, %{
          total_r: total,
          ending: :manual_close,
          closed_at: DateTime.utc_now(),
          note: "flattened via RiptideExecutor.flatten/1"
        })

        IO.puts(
          ">>> DONE — exit #{Float.round(r_exit, 3)}R, total #{Float.round(total, 3)}R. Books closed."
        )

      {:error, reason} ->
        IO.puts("🛑🛑 Flatten REJECTED — #{inspect(reason)}. POSITION STILL OPEN. Go to the venue's website and close it by hand.")
    end
  end

  @doc """
  Place a manual stop at `price` on a trade's remaining position.
  For incidents where the walk died and the position needs protection.
  """
  def protect(key, price) do
    case ManagedTrade.state(key) do
      {:ok, %{phase: :walking, pos: pos, entry: entry, stop: stop}} when pos > 0.0 ->
        dir = if stop <= entry, do: 1, else: -1
        side = if dir == 1, do: :sell, else: :buy

        case TradeEngine.venue_module().place_stop(%{
               side: side,
               qty: pos,
               trigger_price: price * 1.0,
               tag: :stop
             }) do
          {:ok, ref} ->
            IO.puts("🛡 Stop placed: #{pos} BTC #{side} trigger $#{price} — ref #{inspect(ref)}")

          {:error, reason} ->
            IO.puts("🛑 Stop placement FAILED — #{inspect(reason)}. Position UNPROTECTED.")
        end

      _ ->
        IO.puts("No live walking position for #{inspect(key)} — nothing to protect.")
    end

    :ok
  end
end

