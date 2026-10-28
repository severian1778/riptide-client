defmodule RiptideExecutor.Hyperliquid.Venue do
  @moduledoc """
  Hyperliquid adapter for the Venue behaviour.

  The largest adapter in the tree, because Hyperliquid has no native
  primitives for two of the walk's needs: no market orders (markets
  are synthesized as IoC limits at a slippage-buffered mid) and no
  in-place stop modification (the ratchet is cancel + re-place, per
  the Venue contract). Everything venue-specific about BTC-perp
  trading on HL lives here; nothing above the Venue behaviour knows
  any of it.

  ## Asset id — the mainnet/testnet trap

  BTC perp asset id: 0 on mainnet, 3 on testnet (confirmed live).
  Perpetual orders address the asset by its INTEGER INDEX in the
  exchange's meta info, not by symbol — and the indices differ
  between networks for almost every coin (of ~207 shared perps,
  nearly all have different IDs; BTC 0↔3 and ETH 1↔4 are the
  canonical example)^1,2^. asset/0 switches on testnet? so the
  same code serves both networks; if a second perp symbol is ever
  traded, this hard-coded pair must become a lookup against the
  meta endpoint per network — hard-coding further IDs is the
  documented failure mode^1^.

  ## Mapping decisions

    - place_market  → IoC limit at a slippage-buffered mid (no native
      market orders on Hyperliquid)
    - place_limit   → GTC limit (the bank rungs, reduce-only)
    - place_stop    → trigger order, isMarket true, tpsl "sl",
      reduce-only — the ratchet is cancel + re-place
    - order_status  → info orderStatus, plus the fill price captured
      at placement time (see @fill_table)
    - balance       → clearinghouseState marginSummary accountValue
    - positions     → clearinghouseState assetPositions
    - mark_price    → allMids "BTC"
    - set_leverage  → updateLeverage action: ISOLATED margin,
      HYPERLIQUID_LEVERAGE (default 10) — never cross

  ## FILL PRICE FIDELITY (hard rule — barriers price off actual fills)

  The PLACEMENT response carries avgPx for filled statuses; it is
  captured in @fill_table keyed by oid and served by order_status/1
  first. This is the highest-fidelity price the venue will ever
  offer for an IoC order: the placement response IS the execution
  report. The ledger may only record exits the exchange executed —
  timeout/expiry exits are reduce-only market orders, whose fill is
  booked verbatim.

  ## ORDER STATUS SHAPE (pinned live 2026-10-28)

  The orderStatus endpoint returns
  %{"order" => %{"order" => {...basic order...}, "status" => "..."}}
  — status on the OUTER of the nested pair, order fields on the
  inner. An earlier parse read the wrong level (and matched a
  nonexistent "orderStatuses" array), which made every poll error
  and froze live walks with TP1 filled and the stop unratcheted.
  A TRIGGERED STOP becomes a MARKET order, which carries no "px" —
  a missing/zero price is reported as nil (caller falls back to the
  trigger price), never as a fill at $0.

  ## Size precision — known gap, flagged

  Sizes are sent as canonical wire floats WITHOUT flooring to the
  venue's szDecimals (BTC is 3 decimals). Hyperliquid truncates an
  oversized size at its API layer (e.g. 0.0012345678 → 0.00123 on
  testnet's 5-decimal coin) rather than rejecting^1^, so orders
  currently EXECUTE at the venue-truncated size while the walk's
  books assume the untruncated one — a small book-vs-venue drift on
  odd sizes. The clean fix (floor in sz_str/1 like the KuCoin
  adapter's to_contracts/1) is flagged, not applied, in this docs
  pass.
  """

  require Logger

  @behaviour RiptideExecutor.Venue

  # The IoC "market" buffer: half a percent through the mid. Wide
  # enough to cross the book and fill under normal BTC liquidity,
  # tight enough that the fill doesn't give away more than the
  # tier geometry can absorb. The WALK still books the ACTUAL fill
  # (avgPx), so the buffer costs nothing when the book is thin.
  @slippage 0.005

  # Named public ETS table: oid → fill price for orders whose fill
  # was known at PLACEMENT time. See the fill-capture section below.
  @fill_table :hl_fill_prices

  # BTC perp asset id: 0 mainnet, 3 testnet (confirmed live; IDs
  # differ per network — see moduledoc's asset-id trap).
  defp asset, do: if(client().testnet?(), do: 3, else: 0)

  # === Leverage — ISOLATED, never cross ===

  # updateLeverage is a SIGNED exchange action. isCross: false is
  # the isolated-margin switch — a liquidation consumes only this
  # trade's margin, never the account. The walk calls this
  # best-effort before every entry; a failure logs and proceeds
  # (a stale leverage config degrades the position's margin
  # efficiency, not its safety).
  @impl RiptideExecutor.Venue
  def set_leverage do
    lev = String.to_integer(System.get_env("HYPERLIQUID_LEVERAGE", "10"))

    action = [
      {"type", "updateLeverage"},
      {"asset", asset()},
      {"isCross", false},
      {"leverage", lev}
    ]

    case client().exchange(action) do
      {:ok, _} ->
        Logger.info("Hyperliquid: leverage set to #{lev}x ISOLATED")
        :ok

      {:error, %{"error" => e}} when is_binary(e) ->
        Logger.warning("Hyperliquid: set_leverage — #{e}")
        {:error, e}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # === Orders ===

  # "Market" = IoC limit at mid ± 0.5%. If it doesn't fully cross,
  # the unfilled remainder is killed by the venue (Ioc semantics) —
  # which is exactly the market-order property wanted: everything
  # or the known-remainder, never a resting surprise. The returned
  # ref (when filled) carries avgPx captured into the fill table.
  @impl RiptideExecutor.Venue
  def place_market(%{side: side, qty: qty, reduce_only: ro}) do
    {:ok, mid} = mid_price()
    px = if side == :buy, do: mid * (1 + @slippage), else: mid * (1 - @slippage)

    do_order(side, qty, px, ioc_type(), ro)
  end

  # The bank rungs: plain GTC limits. They REST — possibly for
  # hours — and the walk learns of their fill only through
  # order_status polling. reduce_only comes from the caller and is
  # always true for banks: the venue then guarantees the order can
  # never open or flip a position.
  @impl RiptideExecutor.Venue
  def place_limit(%{side: side, qty: qty, price: price, reduce_only: ro}) do
    do_order(side, qty, price, gtc_type(), ro)
  end

  # The ratchet's stop: a trigger order with isMarket: true (when
  # triggerPx is breached, execute a MARKET order) and tpsl: "sl"
  # (this is a stop-loss flavor trigger). reduce_only is hardcoded
  # true — a stop must only ever close. Note the "price" argument
  # passed to do_order is the TRIGGER price; the trigger-type map
  # carries the real semantics and the venue ignores the limit px
  # for isMarket triggers.
  @impl RiptideExecutor.Venue
  def place_stop(%{side: side, qty: qty, trigger_price: trigger}) do
    trigger_type = [
      {"trigger",
       [
         {"isMarket", true},
         {"triggerPx", px_str(trigger)},
         {"tpsl", "sl"}
       ]}
    ]

    do_order(side, qty, trigger, trigger_type, true)
  end

  # Cancel with the already-gone translation: HL's "Order was never
  # placed" (their phrasing for a dead/unknown oid) maps to :ok —
  # the ratchet races triggers routinely and a cancel losing the
  # race must read as success, not failure. Every OTHER error is
  # preserved verbatim for the caller's logging.
  @impl RiptideExecutor.Venue
  def cancel(oid) do
    action = [
      {"type", "cancel"},
      {"cancels", [[{"a", asset()}, {"o", oid}]]}
    ]

    case client().exchange(action) do
      {:ok, _} ->
        :ok

      {:error, %{"error" => e}} when is_binary(e) ->
        if e =~ "Order was never placed", do: :ok, else: {:error, e}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # === Fill polling ===

  # Real response shape: %{"order" => %{"order" => %{...}, "status" => ...}}.
  # A resting maker fills AT its limit price (that IS the execution
  # price for a maker — no avgPx exists on this path, and none is
  # needed). A triggered stop becomes a market order with NO px —
  # fill_price is nil there, and the caller books the trigger price
  # instead. Never book $0.
  #
  # Level-parse notes: `inner` is the outer map under "order"
  # (carries "status"); `order` is the nested basic order (carries
  # "px", side, size). The `|| inner` fallback tolerates a flat
  # response shape so a future API change fails loud-ish rather
  # than nil-crashing.
  @impl RiptideExecutor.Venue
  def order_status(oid) do
    case remembered_fill(oid) do
      # The placement response already reported this fill (avgPx) —
      # that IS the fill, more faithful than anything orderStatus
      # can reconstruct afterwards. Served first, forever.
      {:ok, px} ->
        {:ok, %{"filled" => true, "fill_price" => px, "active" => false}}

      :none ->
        case client().order_status(oid) do
          {:ok, outer} ->
            inner = outer["order"] || %{}
            order = inner["order"] || inner
            status = inner["status"] || order["status"]

            raw_px = px(order["px"])
            # > 0.0 guard: a missing or zero px means "no execution
            # price recoverable" (triggered-stop market conversion)
            # — nil, so the caller falls back to its own reference.
            # This nil-not-zero rule is the fix for the -201.9R
            # mis-booking of 2026-10-28.
            fill_price = if is_number(raw_px) and raw_px > 0.0, do: raw_px, else: nil

            cond do
              status == "filled" ->
                {:ok, %{"filled" => true, "fill_price" => fill_price, "active" => false}}

              status == "open" ->
                {:ok, %{"filled" => false, "fill_price" => nil, "active" => true}}

              # Everything else ("triggered", "canceled", "rejected"):
              # not filled from the walk's perspective. "triggered"
              # keeps active: true — the trigger fired but the
              # resulting market order may still be executing; the
              # NEXT poll will see it filled (or the cancel will
              # have killed it). This middle state is brief but real.
              true ->
                {:ok,
                 %{
                   "filled" => false,
                   "fill_price" => nil,
                   "active" => status == "triggered"
                 }}
            end

          {:error, _} = e ->
            e
        end
    end
  end

  # Boolean convenience — thin over order_status, error-transparent.
  @impl RiptideExecutor.Venue
  def order_filled?(oid) do
    case order_status(oid) do
      {:ok, %{"filled" => f}} -> {:ok, f}
      {:error, r} -> {:error, r}
    end
  end

  # === Account ===

  # Single-number balance from the perps clearinghouse state. Note
  # the unified-account caveat in balance_detail below — this
  # simple view can understate the account when spot collateral
  # backs the perps book.
  @impl RiptideExecutor.Venue
  def balance do
    case client().clearinghouse_state() do
      {:ok, %{"marginSummary" => %{"accountValue" => v}}} -> {:ok, %{"accountValue" => px(v)}}
      {:error, _} = e -> e
    end
  end

  @doc """
  Both accounts, delineated. balance_detail/0 returns
  %{perps: %{...}, spot: %{...}, total: float} — the perps side from
  clearinghouseState, the spot side from spotClearinghouseState.
  Under Hyperliquid's unified account the perps book can sit near zero
  while positions are margined from spot collateral — reporting one
  without the other understates the account.

  spot balances are reduced to {coin, total, hold} triples with
  zero-total entries dropped (the API reports rows for dust and
  historically-touched tokens); spot_usdc is the USDC sum because
  USDC is the collateral unit that moves between the two books.
  """
  def balance_detail do
    with {:ok, perps} <- client().clearinghouse_state(),
         {:ok, spot} <- client().spot_clearinghouse_state() do
      perps_value = px(perps["marginSummary"]["accountValue"])
      margin_used = px(perps["marginSummary"]["totalMarginUsed"])
      withdrawable = px(perps["withdrawable"])

      spot_balances =
        (spot["balances"] || [])
        |> Enum.map(fn b -> %{coin: b["coin"], total: px(b["total"]), hold: px(b["hold"])} end)
        |> Enum.reject(&(&1.total == 0.0))

      spot_usdc =
        spot_balances
        |> Enum.filter(&(&1.coin == "USDC"))
        |> Enum.map(& &1.total)
        |> Enum.sum()

      {:ok,
       %{
         perps: %{
           account_value: perps_value,
           margin_used: margin_used,
           withdrawable: withdrawable,
           open_positions: length(perps["assetPositions"] || [])
         },
         spot: %{balances: spot_balances, usdc: spot_usdc},
         total: perps_value + spot_usdc
       }}
    else
      e -> e
    end
  end

  @doc "Boxed two-account balance — RiptideExecutor.Hyperliquid.Venue.print_balance/0"
  def print_balance do
    case balance_detail() do
      {:ok, d} ->
        IO.puts("""

        ╔══════════════════════════════════════════════════════════╗
        ║  💰 BALANCE — #{master_address()}
        ╟──────────────────────────────────────────────────────────╢
        ║  ▸ PERPS
        ║     account value   $#{fmt_p(d.perps.account_value)}
        ║     margin used     $#{fmt_p(d.perps.margin_used)}
        ║     withdrawable    $#{fmt_p(d.perps.withdrawable)}
        ║     open positions  #{d.perps.open_positions}
        ║  ▸ SPOT
        """)

        if d.spot.balances == [] do
          IO.puts("║     (empty)")
        else
          Enum.each(d.spot.balances, fn b ->
            IO.puts(
              "║     #{String.pad_trailing(b.coin, 10)} #{usd(b.total)}" <>
                if(b.hold > 0.0, do: "   (#{usd(b.hold)} on hold)", else: "")
            )
          end)
        end

        IO.puts("""
        ╠══════════════════════════════════════════════════════════╣
        ║  💵 TOTAL PORTFOLIO  $#{fmt_p(d.total)}
        ╚══════════════════════════════════════════════════════════╝
        """)

        :ok

      {:error, reason} ->
        IO.puts("🛑 balance error: #{inspect(reason)}")
        :error
    end
  end

  defp master_address, do: RiptideExecutor.Hyperliquid.Client.master_address()

  # Raw assetPositions — adapter-defined shape per the Venue
  # contract; the consumers are Reconcile (existence check only)
  # and print_positions (display). No walk logic parses this.
  @impl RiptideExecutor.Venue
  def positions do
    case client().clearinghouse_state() do
      {:ok, %{"assetPositions" => aps}} -> {:ok, aps}
      {:error, _} = e -> e
    end
  end

  # allMids mid — the same reference the venue's own trigger
  # machinery tracks, so the walk's breach checks and the venue's
  # stop triggers agree on what the market is doing.
  @impl RiptideExecutor.Venue
  def mark_price do
    mid_price()
  end

  # === Console views ===

  @doc "Pretty-printed open positions — RiptideExecutor.Hyperliquid.Venue.print_positions/0"
  def print_positions do
    case positions() do
      {:ok, []} ->
        IO.puts("✨ flat — no open positions")

      {:ok, aps} ->
        IO.puts("📊 OPEN POSITIONS (#{length(aps)})\n")

        Enum.each(aps, fn ap ->
          pos = ap["position"]
          szi = px(pos["szi"])
          entry = px(pos["entryPx"])
          pnl = px(pos["unrealizedPnl"])
          pnl_pct = px(pos["returnOnEquity"]) * 100.0
          margin = px(pos["marginUsed"])
          notional = px(pos["positionValue"])
          lev = pos["leverage"]
          funding = px(pos["cumFunding"]["allTime"])

          dir = if szi > 0.0, do: "🟢 LONG", else: "🔴 SHORT"

          lev_str =
            case lev do
              %{"type" => t, "value" => v} -> "#{v}x #{t}"
              _ -> "?"
            end

          IO.puts("""
          ╔══════════════════════════════════════════════════════════╗
          ║  #{dir}  BTC-PERP
          ╟──────────────────────────────────────────────────────────╢
          ║   size      #{fmt_sz(szi)} BTC
          ║   entry     $#{fmt_p(entry)}
          ║   mark      $#{fmt_p(mark())}
          ║   notional  $#{fmt_p(notional)}   (#{lev_str}, margin $#{fmt_p(margin)})
          ║   pnl       #{pnl_str(pnl, pnl_pct)}
          ║   funding   $#{fmt_p(funding)} paid
          ╚══════════════════════════════════════════════════════════╝
          """)
        end)

      {:error, reason} ->
        IO.puts("🛑 venue error: #{inspect(reason)}")
    end

    :ok
  end

  # === Private: fill-price capture ===

  # WHY A TABLE: an IoC order's fill happens DURING placement, and
  # the placement response's avgPx is the only exact execution
  # price the API ever reports for it. The walk asks about this oid
  # seconds later via orderStatus — which reconstructs the fill
  # less faithfully. So: capture avgPx at placement into the table,
  # serve it first in order_status forever after. The table is an
  # in-memory journal of "fills we personally executed"; oids we
  # never placed (restarts) fall through to the polling path.

  defp remember_fill(oid, px) do
    ensure_fill_table()
    :ets.insert(@fill_table, {oid, px})
  end

  defp remembered_fill(oid) do
    ensure_fill_table()

    case :ets.lookup(@fill_table, oid) do
      [{_, px}] -> {:ok, px}
      [] -> :none
    end
  end

  # Idempotent creation with the race handled: two processes can
  # both see :undefined and both try :ets.new; the loser's
  # ArgumentError is rescued and treated as success (the table
  # exists either way). Same pattern as the nonce counter's
  # persistent_term race — tolerated because both racers want the
  # same outcome.
  defp ensure_fill_table do
    case :ets.whereis(@fill_table) do
      :undefined ->
        try do
          :ets.new(@fill_table, [:set, :named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # === Private: order construction ===

  defp ioc_type, do: [{"limit", [{"tif", "Ioc"}]}]
  defp gtc_type, do: [{"limit", [{"tif", "Gtc"}]}]

  # The one order-shape builder. Pair-lists (not maps) because the
  # Client signs the MessagePack of this exact structure — map key
  # ordering would be nondeterministic; pair-list order is fixed
  # here in code. "b" is the boolean side, "r" reduce-only, "t"
  # the order-type payload (limit or trigger variant).
  defp do_order(side, qty, price, order_type, reduce_only) do
    order = [
      {"a", asset()},
      {"b", side == :buy},
      {"p", px_str(price)},
      {"s", sz_str(qty)},
      {"r", reduce_only},
      {"t", order_type}
    ]

    action = [
      {"type", "order"},
      {"orders", [order]},
      {"grouping", "na"}
    ]

    case client().exchange(action) do
      # Exactly one order per request → exactly one status; the head
      # is ours. (Batching was rejected at design time — single
      # orders keep the fill-capture and error attribution simple.)
      {:ok, %{"data" => %{"statuses" => [status | _]}}} ->
        unwrap_oid(status)

      {:ok, resp} ->
        {:error, {:unexpected_exchange_response, resp}}

      {:error, _} = e ->
        e
    end
  end

  # The three placement outcomes:
  #   - "filled": instant execution (the IoC entry case) — oid plus
  #     avgPx, the ACTUAL fill price. Captured before anything can
  #     lose it (see fill-capture section). avgPx absent (e.g.
  #     partial IoC reported without px) → capture nothing, fall
  #     through to polling.
  #   - "resting": the order is live on the book — oid only; its
  #     fill (if any) will be discovered by polling.
  #   - "error": venue-level rejection (bad size, insufficient
  #     margin, off-grid price) → {:error, {:order_rejected, ...}}
  #     — the walk treats this as information, never a crash.
  defp unwrap_oid(%{"filled" => %{"oid" => oid} = filled}) when is_integer(oid) do
    case filled["avgPx"] do
      px when is_binary(px) -> remember_fill(oid, px(px))
      _ -> :ok
    end

    {:ok, oid}
  end

  defp unwrap_oid(%{"resting" => %{"oid" => oid}}) when is_integer(oid), do: {:ok, oid}
  defp unwrap_oid(%{"error" => e}), do: {:error, {:order_rejected, e}}
  defp unwrap_oid(other), do: {:error, {:unexpected_status, other}}

  defp client, do: RiptideExecutor.Hyperliquid.Client

  # === Private: helpers ===

  # The BTC mid specifically; a response without one is a distinct
  # error (:no_btc_mid) so a symbol-list change fails diagnosably
  # rather than as a generic mismatch.
  defp mid_price do
    case client().all_mids() do
      {:ok, %{"BTC" => mid}} -> {:ok, px(mid)}
      {:ok, _} -> {:error, :no_btc_mid}
      {:error, _} = e -> e
    end
  end

  # Display-only mark (0.0 on failure — print paths never gate on
  # it; the walk's REAL mark is mark_price/0 which propagates
  # errors).
  defp mark do
    case mid_price() do
      {:ok, m} -> m
      _ -> 0.0
    end
  end

  # === Precision ===
  # px ≤ 5 significant figures (API limit), then canonical wire float
  # (trailing zeros stripped — "80334.0" -> "80334"). Sizes: canonical
  # wire float. KNOWN GAP (see moduledoc): sizes are NOT floored to
  # szDecimals — the venue truncates silently, so odd sizes execute
  # slightly smaller than booked.

  # Prices: significant-figure rounding. HL accepts prices with at
  # most 5 significant figures; anything finer is rejected — the
  # walk's computed levels (entry ± percentages) carry full float
  # noise and MUST be rounded here or every order bounces.
  defp px_str(p) when is_number(p), do: sig_fig(p, 5) |> wire_float()
  defp sz_str(s) when is_number(s), do: wire_float(s * 1.0)

  # Round to n significant figures: scale by 10^(n-1-exponent),
  # round, scale back. Zero handled first (log10 of 0 is -inf).
  # The final * 1.0 keeps the result a float even when the division
  # lands on an integer.
  defp sig_fig(x, n) do
    if x == +0.0 do
      0.0
    else
      exp = trunc(:math.floor(:math.log10(abs(x))))
      factor = :math.pow(10, n - 1 - exp)
      round(x * factor) / factor * 1.0
    end
  end

  # Canonical wire float: fixed 8-decimal rendering with trailing
  # zeros (and a bare ".0") stripped — "80334.0" → "80334",
  # "0.01000000" → "0.01". HL's string parsers accept these; the
  # stripping exists so the LOGGED body matches what the server
  # stores and displays.
  defp wire_float(x) do
    case String.split(:erlang.float_to_binary(x * 1.0, decimals: 8), ".") do
      [int_part, frac] ->
        case String.trim_trailing(frac, "0") do
          "" -> int_part
          f -> int_part <> "." <> f
        end

      [only] ->
        only
    end
  end

  # === Display formatters ===

  defp pnl_str(pnl, pct) do
    icon = if pnl >= 0.0, do: "▲", else: "▼"
    "#{icon} #{if pnl >= 0, do: "+", else: ""}#{fmt_p(pnl)}  (#{pct_str(pct)})"
  end

  defp pct_str(pct), do: "#{if pct >= 0, do: "+", else: ""}#{Float.round(pct, 2)}%"

  defp fmt_sz(s), do: :erlang.float_to_binary(s * 1.0, decimals: 4)
  defp fmt_p(p), do: Float.round(p * 1.0, 2) |> :erlang.float_to_binary(decimals: 2)
  defp usd(x), do: Float.round(x * 1.0, 2) |> :erlang.float_to_binary(decimals: 2)

  # The universal API-value → float coercion. HL reports numbers as
  # STRINGS in JSON ("80879.1") in some responses and numbers in
  # others; px/1 accepts both. The :error → 0.0 fallback on parse
  # failure is DELIBERATE for display paths but is guarded against
  # for fill prices by order_status's > 0.0 check — a malformed
  # price string can never be booked as a real fill.
  defp px(v) when is_float(v), do: v
  defp px(v) when is_integer(v), do: v * 1.0

  defp px(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp px(_), do: 0.0
end

