defmodule RiptideExecutor.ManagedTrade do
  @poll_ms 5_000

  @moduledoc """
  Walks one ladder trade against a Venue — the executor-side twin of
  RiptideAI.LadderRunner's walk, with the fund's entry protocol.

  One GenServer process per accepted ladder trade, registered in
  TradeRegistry under the dedupe triple {symbol, market_type,
  anchor_ts}. Started by TradeEngine via TradeSupervisor; lifecycle:

      init → :open → [late? → Oracle verdict | queue] → anchor pulse
      → verdict → entry → :walking (pulse-driven bars + 5s fill
      polls) → bank/ratchet/escalate → exit → {:stop, :normal}

  ## HARD RULES (enforced here, pinned by test)

  1. ENTRY PROTOCOL — queue → anchor verdict → entry. Zero orders
     until the anchor candle closes; entry lands one minute after
     the anchor. EVERY SIGNAL TRADES — no skips. An anchor closing
     AGAINST the direction ("absorbed") forces close_mult ×0.5.
     Late registration asks the Oracle best-effort; unavailable →
     trade at the broadcast multiple.
  2. SIZING — kelly_eff = min(kelly × close_mult × quiet_mult,
     KELLY_CAP); multiples ride the broadcast (×1 absent). Size is
     floored to the venue min (0.001 BTC), never rounded up.
  3. R ACCOUNTING — position FRACTION (pos/init_qty), so a full
     stop-out is exactly -1R at any size. Banked R accumulates and
     is credited at the final close; dollars = total_r ×
     capital_risked.
  4. THE WALK — stop checked first (pessimistic: if both stop and
     bank appear filled in one poll, the stop wins and the trade
     is booked as a loss, never as a bank-then-continue). Bank half
     at each tier's tp2, ratchet the stop to half that tier's tp2
     (tp2_pct/200), escalate on timeout. Final tier banks once then
     rides to final_expiry. Timeouts are bar-counted PER TIER — the
     counter resets to zero on every tier advance. Tiers walk
     shortest horizon first, sorted HERE regardless of broadcast
     order (a broadcast once shipped 12h before 3h; the sort is
     idempotent, so it is always applied).
  5. EXITS EXECUTE — the ledger only records exits the exchange
     actually did; a rejected exit retries on the next poll. Never
     booked as a phantom close, never crashed into a restart.
  6. NEVER STACK — an entry fill already in the ledger means a
     previous incarnation opened this trade (restart after a
     crash): the walk REFUSES to re-open and leaves the record
     OPEN for Reconcile to flag. Exchange refusals are information,
     never crashes.
  7. REPORTING — absorbed, close_mult, quiet_mult, kelly_eff, and
     capital_risked on every record.
  8. DEADZONE — |ofi| <= 0.05 (order flow too quiet to trust the
     push) → :deadzone_skip, zero orders. A property of the signal
     itself; no verdict or multiple overrides it.
  9. NEVER UNPROTECTED — the new stop is placed BEFORE the old one
     is cancelled (a failed placement leaves the old stop
     standing). NO bare pattern matches on venue placement results
     anywhere — the 2026-10-28 duplicate-nonce MatchError crashed
     the walk mid-ratchet, cancelling the old stop and dying before
     placing the new one. The poll re-places a missing stop before
     checking anything else. A stop that cannot be placed at ENTRY
     flattens the position immediately (:stop_lost); a flatten that
     ALSO fails leaves the ledger open for Reconcile + manual
     intervention, logged at 🛑🛑.

  ## Fill detection (post-2026-10-28 fix — read this before
  touching Client.order_status)

  The walk learns of fills ONLY through order_status/1 polling —
  placement acks mean nothing (a resting order accepted ≠ filled).
  The Hyperliquid orderStatus response nests status on the outer
  of {%{"order" => %{"order" => {...}, "status" => ...}}}: reading
  the wrong level made every poll return an error, the walk froze
  with TP1 filled and the stop unratcheted, and errors were
  swallowed as "not filled" by the old binary filled?. filled?/2
  now LOGS every error — a silent poll loop is a bug, not a state.

  ## Known accepted limitation

  Tier advancement requires a FULL bank fill. A partially-filled
  bank limit stalls the walk at that tier (no ratchet, no
  escalation) until the rest fills or the tier timeout fires. This
  is a deliberate design decision (full fill = the level actually
  traded), revisited 2026-10-28 and kept. If it bites again, the
  fix is booking the partial qty and keeping the remainder resting.
  """

  use GenServer, restart: :transient

  require Logger

  alias RiptideExecutor.Ledger

  # Poll cadence for venue fill checks. Trade-offs: shorter = faster
  # fill reaction, more API weight; longer = slower ratchets. 5s is
  # ~1/12 of the shortest decision interval (1m bars) — fast enough
  # that a stop fill is booked within one bar.
  @poll_ms 5_000

  # === Public API ===

  @doc "Started by TradeSupervisor with the args tuple built in TradeEngine.execute/1."
  def start_link({venue, oracle, key, ladder, bankroll}) do
    GenServer.start_link(__MODULE__, {venue, oracle, key, ladder, bankroll}, name: via(key))
  end

  # :via Registry name — process-level uniqueness AND lookup by key.
  # Status and Reconcile find a live walk by key without asking the
  # supervisor. (Supervisor-level uniqueness is a separate guard —
  # the child id in TradeSupervisor.)
  defp via(key), do: {:via, Registry, {RiptideExecutor.TradeRegistry, key}}

  @doc """
  Live walk state for the console status view (Status) and
  reconciliation (Reconcile's running?/1 test).

  Catches exits: a trade dying mid-call returns {:error, :down},
  never propagates a crash into the CALLER. The 5s timeout bounds
  the call in case the walk is stuck in a slow venue request.
  """
  def state(key) do
    case Registry.lookup(RiptideExecutor.TradeRegistry, key) do
      [{pid, _}] ->
        try do
          {:ok, GenServer.call(pid, :state, 5_000)}
        catch
          :exit, _ -> {:error, :down}
        end

      [] ->
        {:error, :not_running}
    end
  end

  # === QUEUE ===

  # init defers all real work to a :open message 100ms later — the
  # process must be registered and callable before the verdict path
  # (which does venue calls) runs, or Status/Reconcile could hit a
  # nameless pid mid-init.
  @impl true
  def init({venue, oracle, key, ladder, bankroll}) do
    Process.send_after(self(), :open, 100)
    {:ok, %{venue: venue, oracle: oracle, key: key, ladder: ladder, bankroll: bankroll}}
  end

  # Three :state clauses mirror the phases. The awaiting view shows
  # tier-1 geometry with pos 0 (nothing has happened yet); the
  # initializing clause covers the 100ms window before :open runs.

  @impl true
  def handle_call(:state, _from, %{phase: :awaiting} = s) do
    {:reply,
     %{
       phase: :awaiting,
       key: s.key,
       anchor_ts: s.anchor_ts,
       tier: 0,
       horizon: hd(s.tiers)["horizon"],
       tier_bars: hd(s.tiers)["bars"],
       bars: 0,
       pos: 0.0,
       stop: nil,
       entry: nil,
       price: s.price,
       banked: 0.0,
       final_banked: false
     }, s}
  end

  @impl true
  def handle_call(:state, _from, %{phase: :walking} = s) do
    tier = cur_tier(s)

    {:reply,
     %{
       phase: :walking,
       key: s.key,
       tier: s.tier,
       horizon: tier["horizon"],
       bars: s.bars,
       tier_bars: tier["bars"],
       pos: s.pos,
       stop: s.stop,
       banked: s.banked,
       entry: s.entry,
       price: s.price,
       final_banked: s.final_banked
     }, s}
  end

  @impl true
  def handle_call(:state, _from, s) do
    {:reply, %{phase: :initializing, key: s.key}, s}
  end

  # :open — build the walk state and route: late registration goes
  # straight to verdict via the Oracle; on-time registration queues
  # until the anchor pulse.
  @impl true
  def handle_info(:open, s) do
    anchor =
      case DateTime.from_iso8601(s.ladder["anchor_ts"]) do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        # Unparseable anchor: fall back to "now, floored" — the trade
        # then immediately counts as late and trades on the Oracle/
        # broadcast path rather than crashing. Malformed input never
        # kills the walk.
        _ -> floor_to_minute(DateTime.utc_now())
      end

    # Subscribed to the pulse stream BEFORE any verdict runs — the
    # anchor-close pulse is what an on-time trade waits for.
    Registry.register(RiptideExecutor.PulseRegistry, :minute, nil)

    s =
      Map.merge(s, %{
        dir: if(s.ladder["direction"] == "bullish", do: 1, else: -1),
        anchor_ts: anchor,
        ref_price: s.ladder["entry_price"] * 1.0,
        # Walk shortest horizon first, regardless of broadcast order
        # (bars ascending = 3h → 6h → 12h → 24h → 2d). Idempotent on
        # already-sorted input.
        tiers: Enum.sort_by(s.ladder["tiers"], & &1["bars"]),
        phase: :awaiting,
        stop_ref: nil,
        bank_ref: nil,
        bars: 0,
        banked: 0.0,
        price: s.ladder["entry_price"] * 1.0,
        exit_pending: nil
      })

    if DateTime.diff(DateTime.utc_now(), anchor, :second) >= 60 do
      # Late registration — anchor already closed, its pulse is gone
      # forever. Verdict from the Oracle best-effort; nil → trade at
      # the broadcast multiple. NO SKIPS (HARD RULE 1).
      verdict(s, s.oracle.close_at_bar(anchor))
    else
      Logger.info(
        "ManagedTrade: ⏳ QUEUED #{s.ladder["direction"]} #{s.ladder["symbol"]} — awaiting anchor bar close"
      )

      schedule_poll()
      {:noreply, s}
    end
  end

  # === PULSE ===

  # Awaiting phase: the pulse AT anchor+60s carries the anchor
  # candle's close → the verdict, then entry. A pulse arriving LATE
  # (diff > 60 — the trade queued but missed the exact pulse, e.g.
  # registered between pulses) falls back to the Oracle. Earlier
  # pulses are ignored — the anchor candle hasn't closed yet.
  @impl true
  def handle_info({:pulse, bar_ts, price}, %{phase: :awaiting} = s) do
    diff = DateTime.diff(bar_ts, s.anchor_ts, :second)

    cond do
      diff == 60 ->
        verdict(s, price)

      diff > 60 ->
        verdict(s, s.oracle.close_at_bar(s.anchor_ts))

      true ->
        {:noreply, s}
    end
  end

  # Walking phase: every pulse is one bar. A nil pulse price (data
  # hole) keeps counting bars and holds the last price — a data
  # hole must not freeze the bar count or the timeout machinery.
  @impl true
  def handle_info({:pulse, _bar_ts, price}, %{phase: :walking} = s) do
    s = %{s | bars: s.bars + 1, price: price || s.price}

    if s.bars >= cur_tier(s)["bars"] do
      tier_timeout(s)
    else
      {:noreply, s}
    end
  end

  # === POLL ===

  @impl true
  def handle_info(:poll, %{phase: :awaiting} = s) do
    # Waiting-phase polls are pure keepalive — nothing to check yet;
    # the anchor PULSE is what moves an awaiting trade, not a poll.
    schedule_poll()
    {:noreply, s}
  end

  # Pending exit: the ONLY thing left to do is execute it. Retries
  # forever on venue rejection (HARD RULE 5) — the stop may have
  # been cancelled, so a rejection loop is still safer than a
  # phantom close.
  @impl true
  def handle_info(:poll, %{phase: :walking, exit_pending: ending} = s) when not is_nil(ending) do
    attempt_exit(s, ending)
  end

  # The normal poll — the walk's senses. Order matters and is
  # load-bearing:
  #   1. missing stop  → replace FIRST (protection before profit)
  #   2. stop filled   → trade is OVER (pessimistic check first)
  #   3. bank filled   → the walk advances
  @impl true
  def handle_info(:poll, %{phase: :walking} = s) do
    cond do
      s.stop && is_nil(s.stop_ref) ->
        # A stop placement failed earlier — re-place BEFORE anything
        # else. The position must never sit unprotected.
        replace_stop(s)

      filled?(s.venue, s.stop_ref) ->
        # The stop trigger FILLED on the venue — the position is
        # already closed there. Cancel the resting bank; book at the
        # stop's fill price. (A triggered stop converts to a market
        # order with no px — fill_price! falls back to the trigger
        # level, per the Venue contract: never book $0.)
        if s.bank_ref, do: s.venue.cancel(s.bank_ref)
        s.venue.cancel(s.stop_ref)

        price = fill_price!(s.venue, s.stop_ref, s.stop)
        book_exit(s, price, :stop)

      s.bank_ref && filled?(s.venue, s.bank_ref) ->
        bank_and_advance(s)

      true ->
        schedule_poll()
        {:noreply, s}
    end
  end

  # === The anchor verdict ===

  # absorbed = the anchor candle closed AGAINST the direction
  # (for a long: close below the broadcast entry). Worst-quartile
  # close per the researched multiples table → close_mult forced to
  # ×0.5. In favor or exactly flat → the broadcast close_mult.
  defp verdict(s, anchor_close) when is_number(anchor_close) do
    absorbed? = (anchor_close - s.ref_price) * s.dir < 0.0

    if absorbed? do
      Logger.warning(
        "ManagedTrade: ⚠️ anchor candle ABSORBED the push (close #{fmt(anchor_close)} vs entry #{fmt(s.ref_price)}) — sizing to x0.5, trade proceeds"
      )
    end

    Ledger.update_trade(s.key, %{absorbed: absorbed?, anchor_close: anchor_close * 1.0})
    enter(s, absorbed?)
  end

  # Oracle unavailable — trade at the broadcast multiple. Never
  # blind: there is no skip decision anymore (HARD RULE 1).
  defp verdict(s, nil) do
    Logger.warning("ManagedTrade: anchor close unavailable — trading at the broadcast multiple")
    Ledger.update_trade(s.key, %{absorbed: nil})
    enter(s, false)
  end

  # === ENTER ===

  # HARD RULE 6 — never stack: an entry fill already in the ledger
  # means a previous incarnation opened this trade (restart after a
  # crash — e.g. the 2026-10-28 nonce crash, whose restart logged
  # exactly this refusal). Leave the record OPEN so Reconcile flags
  # the exchange state for a human; the walk exits :normal so the
  # :transient policy does NOT restart it again.
  defp enter(s, absorbed?) do
    if Ledger.fills(s.key) != [] do
      Logger.error(
        "ManagedTrade: 🛑 REFUSING to re-open #{inspect(s.key)} — entry fill already in the ledger " <>
          "(restart after crash?). Exchange state needs manual reconciliation."
      )

      {:stop, :normal, s}
    else
      do_enter(s, absorbed?)
    end
  end

  defp do_enter(s, absorbed?) do
    if deadzone?(s.ladder) do
      # HARD RULE 8 — checked BEFORE leverage and any order. The
      # deadzone is a property of the signal; the absorbed-verdict
      # update has already run (absorbed may be recorded on the
      # trade), but no orders exist and none ever will for this key.
      Logger.info(
        "ManagedTrade: ⚪ deadzone (|ofi| <= 0.05, ofi #{s.ladder["ofi"]}) — skipping, no orders"
      )

      Ledger.record_event(s.key, :deadzone_skip, %{ofi: s.ladder["ofi"]})
      Ledger.close_trade(s.key, %{
        total_r: 0.0,
        ending: :deadzone_skip,
        closed_at: DateTime.utc_now()
      })

      {:stop, :normal, s}
    else
      venue = s.venue
      side = if s.dir == 1, do: :buy, else: :sell
      tier1 = hd(s.tiers)
      risk_est = s.ref_price * tier1["sl_pct"] / 100.0

      # THE RESEARCHED MULTIPLES — close × quiet from the broadcast;
      # an absorbed anchor (worst quartile) forces x0.5 regardless.
      cm = if absorbed?, do: 0.5, else: mult(s.ladder["close_mult"])
      qm = mult(s.ladder["quiet_mult"])

      kelly_base =
        case s.ladder["kelly_fraction"] do
          v when is_number(v) -> v * 1.0
          _ -> 0.0
        end

      # HARD RULE 2 — multiples decide up to the cap, the cap decides
      # the ceiling. KELLY_CAP env (default 0.2).
      kelly_eff = min(kelly_base * cm * qm, num("KELLY_CAP", 0.2))

      # Fixed-fractional sizing: risk kelly_eff × bankroll, position
      # = risk / per-unit-risk. risk_est uses the BROADCAST entry
      # price; risk is re-derived from the ACTUAL fill in
      # finish_enter (the fill can differ from the broadcast).
      qty = s.bankroll * kelly_eff / risk_est

      max_pos = num("MAX_POSITION_BTC", 0.5)
      qty = min(qty, max_pos)
      # Floor at venue minimum rather than skipping: a sub-min signal
      # trades minimum size. (Note: 0.001 / 2 = 0.0005 is below the
      # venue min for the BANK leg — known edge at minimum sizing,
      # bank placement will be rejected and the walk rides the stop.)
      qty = if qty < 0.001, do: 0.001, else: qty

      # Isolated leverage before any order — best-effort by the
      # Venue contract: a config failure must not block the trade.
      case venue.set_leverage() do
        :ok -> :ok
        e -> Logger.warning("ManagedTrade: set_leverage — #{inspect(e)}")
      end

      case venue.place_market(%{side: side, qty: qty, reduce_only: false, tag: :entry}) do
        {:ok, entry_ref} ->
          finish_enter(s, venue, tier1, qty, cm, qm, kelly_eff, absorbed?, entry_ref)

        {:error, reason} ->
          # Exchange refusal at entry is information, not a crash —
          # a crash here would restart and retry, which is how
          # positions stack (HARD RULE 6's reason for existing).
          Logger.error("ManagedTrade: entry rejected — #{inspect(reason)}")
          Ledger.record_event(s.key, :entry_failed, %{reason: inspect(reason)})
          Ledger.close_trade(s.key, %{
            total_r: 0.0,
            ending: :entry_failed,
            closed_at: DateTime.utc_now()
          })

          {:stop, :normal, s}
      end
    end
  end

  # |ofi| <= 0.05 → order-flow too quiet to trust the push. A ladder
  # without an "ofi" field (older broadcasts) is never deadzoned.
  defp deadzone?(%{"ofi" => ofi}) when is_number(ofi), do: abs(ofi) <= 0.05
  defp deadzone?(_), do: false

  # Post-entry protection setup. Ordering is the safety story:
  #   1. STOP first — a failed stop placement flattens immediately
  #      (HARD RULE 9: never hold a naked position).
  #   2. BANK second — a failed bank placement degrades to "ride
  #      the stop" (bank_ref: nil is safe in the poll).
  defp finish_enter(s, venue, tier1, qty, cm, qm, kelly_eff, absorbed?, entry_ref) do
    entry = fill_price!(venue, entry_ref, s.ref_price)

    # Risk re-derived from the ACTUAL fill, not the broadcast —
    # stop/tp2/capital_risked all hang off this. On Hyperliquid the
    # placement response carried avgPx (captured in the venue's
    # fill table); fallback is the broadcast price.
    risk = entry * tier1["sl_pct"] / 100.0
    stop = entry - s.dir * risk
    tp2 = entry + s.dir * entry * tier1["tp2_pct"] / 100.0

    case venue.place_stop(%{side: opp(side_of(s.dir)), qty: qty, trigger_price: stop, tag: :stop}) do
      {:ok, stop_ref} ->
        bank_ref =
          case venue.place_limit(%{
                 side: opp(side_of(s.dir)),
                 qty: qty / 2,
                 price: tp2,
                 reduce_only: true,
                 tag: {:bank, tier1["horizon"]}
               }) do
            {:ok, ref} ->
              ref

            {:error, reason} ->
              # Degrade, never crash: no bank rung means the trade
              # rides to its stop or tier timeout — the timeout
              # escalation re-places bank rungs anyway.
              Logger.error(
                "ManagedTrade: bank limit placement failed — #{inspect(reason)}; riding the stop (no bank rung)"
              )

              nil
          end

        capital_risked = risk * qty

        # Journal the entry fill BEFORE recording the trade fields —
        # on a crash between the two writes, the never-stack guard
        # (fills != []) errs on the side of refusing to re-open.
        Ledger.record_fill(s.key, :entry, %{price: entry, qty: qty})

        Ledger.update_trade(s.key, %{
          entry: entry,
          close_mult: cm,
          quiet_mult: qm,
          kelly_eff: kelly_eff,
          capital_risked: capital_risked
        })

        Logger.info("""
        ManagedTrade: OPEN #{s.ladder["direction"]} #{s.ladder["symbol"]}#{if absorbed?, do: "  [ABSORBED — x0.5]"}
          qty #{fmt(qty)} BTC @ $#{fmt(entry)}   kelly #{Float.round(kelly_eff, 3)} (close x#{cm} quiet x#{qm})
          capital at risk $#{fmt(capital_risked)}   stop trigger $#{fmt(stop)}
          tier1 #{tier1["horizon"]} bank limit $#{fmt(tp2)} (half off)
        """)

        walking =
          Map.merge(s, %{
            phase: :walking,
            entry: entry,
            risk: risk,
            init_qty: qty,
            pos: qty,
            stop: stop,
            tier: 0,
            stop_ref: stop_ref,
            bank_ref: bank_ref,
            opened_at: DateTime.utc_now(),
            final_banked: false,
            exit_pending: nil
          })

        schedule_poll()
        {:noreply, walking}

      {:error, reason} ->
        # HARD RULE 9: never hold an unstop-filled position. If the
        # stop cannot be placed, flatten immediately.
        Logger.error(
          "ManagedTrade: 🛑 STOP placement failed (#{inspect(reason)}) — flattening immediately"
        )

        flatten_now(s, venue, entry, risk, qty, reason)
    end
  end

  # Emergency flatten after a failed entry stop. r is computed
  # against the entry risk — a full-size exit at fill price. The
  # double-failure case (flatten ALSO rejected) is the one state
  # that leaves real money unmanaged: the ledger record is left
  # OPEN (never closed with a fabricated outcome) so Reconcile and
  # Status's 💀 line surface it, and the log is 🛑🛑 — the loudest
  # line in the system.
  defp flatten_now(s, venue, entry, risk, qty, reason) do
    case venue.place_market(%{side: opp(side_of(s.dir)), qty: qty, reduce_only: true, tag: :exit}) do
      {:ok, ref} ->
        fill = fill_price!(venue, ref, entry)
        r = s.dir * (fill - entry) / risk

        Ledger.record_fill(s.key, :stop_exit, %{price: fill, qty: qty})
        Ledger.record_event(s.key, :stop_lost, %{r: r, reason: inspect(reason)})
        Ledger.close_trade(s.key, %{total_r: r, ending: :stop_lost, closed_at: DateTime.utc_now()})

      {:error, e2} ->
        Logger.error(
          "ManagedTrade: 🛑🛑 flatten ALSO failed (#{inspect(e2)}) — POSITION UNPROTECTED, MANUAL INTERVENTION REQUIRED"
        )

        Ledger.record_event(s.key, :flatten_failed, %{reason: inspect(e2)})
        # Ledger left OPEN so Reconcile flags it loudly for a human.
    end

    {:stop, :normal, s}
  end

  # === Walk internals ===

  # R for a fraction of the position at a price: position FRACTION
  # × direction × price-move / per-unit-risk. Fraction-based, so a
  # full stop-out is exactly -1R at ANY position size (HARD RULE 3)
  # and halving the position halves the R exposure of the rest.
  defp r_of(s, fraction_qty, price) do
    fraction_qty / s.init_qty * s.dir * (price - s.entry) / s.risk
  end

  # The bank: half the remaining position filled at this tier's tp2.
  # Books at the NOTIONAL tp2 price (the resting limit's price — a
  # resting maker fills AT its price, so this is the actual fill
  # price whenever the limit filled fully).
  defp bank_and_advance(s) do
    tier = cur_tier(s)
    tp2 = s.entry + s.dir * s.entry * tier["tp2_pct"] / 100.0
    half = s.pos / 2
    r = r_of(s, half, tp2)
    # Ratchet: half the tier's tp2 distance = tp2_pct/200 of entry.
    new_stop = s.entry + s.dir * s.entry * tier["tp2_pct"] / 200.0
    final? = s.tier == length(s.tiers) - 1
    next = if final?, do: nil, else: Enum.at(s.tiers, s.tier + 1)

    # Book the money FIRST — even if everything below crashes, the
    # fill is in the journal (ordering learned from the nonce crash:
    # the journal must never depend on downstream venue calls
    # succeeding).
    Ledger.record_fill(s.key, {:bank, tier["horizon"]}, %{price: tp2, qty: half})
    Ledger.record_event(s.key, :bank, %{tier: tier["horizon"], r: r})

    Logger.info(
      "ManagedTrade: 💰 BANK #{tier["horizon"]} @ $#{fmt(tp2)}  #{r_str(r)}R  stop → $#{fmt(new_stop)}"
    )

    # HARD RULE 9 — place the NEW stop first; only cancel the OLD
    # one once the new is live. If placement fails, the old stop
    # stays standing (still protective at its original level) and
    # stop_ref is unchanged — the walk continues protected.
    stop_res =
      s.venue.place_stop(%{side: side_of(-s.dir), qty: s.pos - half, trigger_price: new_stop, tag: :stop})

    s2 =
      case stop_res do
        {:ok, stop_ref} ->
          s.venue.cancel(s.stop_ref)
          %{s | stop: new_stop, stop_ref: stop_ref}

        {:error, reason} ->
          Logger.error(
            "ManagedTrade: 🛑 stop re-place after bank FAILED — #{inspect(reason)}; old stop at $#{fmt(s.stop)} stays (still protective)"
          )

          s
      end

    # Next tier's bank rung sized off the POST-BANK remainder's next
    # half. Failure degrades to no-rung (timeout escalation
    # re-places); never a crash, never a bare match.
    bank_ref =
      case next do
        nil ->
          nil

        nt ->
          tp2n = s.entry + s.dir * s.entry * nt["tp2_pct"] / 100.0

          case s.venue.place_limit(%{
                 side: side_of(-s.dir),
                 qty: half / 2,
                 price: tp2n,
                 reduce_only: true,
                 tag: {:bank, nt["horizon"]}
               }) do
            {:ok, ref} ->
              ref

            {:error, reason} ->
              Logger.error(
                "ManagedTrade: next bank limit failed — #{inspect(reason)}; continuing without a bank rung (timeout escalation re-places)"
              )

              nil
          end
      end

    s3 = %{
      s2
      | pos: s.pos - half,
        banked: s.banked + r,
        final_banked: s.final_banked or final?,
        # Final tier does NOT escalate past the last tier — the tier
        # index holds and the remaining position rides to expiry.
        tier: if(final?, do: s.tier, else: s.tier + 1),
        bank_ref: bank_ref,
        # Per-tier bar count resets on EVERY tier advance (HARD
        # RULE 4) — timeouts are tier-local, not cumulative.
        bars: 0
    }

    schedule_poll()
    {:noreply, s3}
  end

  # Tier budget exhausted without a bank. Three ways out, in
  # priority order: price already breached the NEW (tighter) stop →
  # timeout_stop (market out at ~the ratcheted level); final tier →
  # final_expiry (ride is over, market out); otherwise escalate to
  # the next tier with the ratcheted stop.
  defp tier_timeout(s) do
    tier = cur_tier(s)
    new_stop = s.entry + s.dir * s.entry * tier["tp2_pct"] / 200.0
    final? = s.tier == length(s.tiers) - 1

    Ledger.record_event(s.key, :timeout_escalate, %{tier: tier["horizon"], bars: s.bars})

    Logger.info(
      "ManagedTrade: ⏰ tier #{tier["horizon"]} timeout at bar #{s.bars} — close $#{fmt(s.price)}, stop ratchets to $#{fmt(new_stop)}"
    )

    cond do
      s.dir == 1 and s.price <= new_stop ->
        exit_pending(%{s | stop: new_stop}, :timeout_stop)

      s.dir == -1 and s.price >= new_stop ->
        exit_pending(%{s | stop: new_stop}, :timeout_stop)

      final? ->
        exit_pending(%{s | stop: new_stop}, :final_expiry)

      true ->
        escalate(s, new_stop)
    end
  end

  # Timeout escalation — same ordering discipline as bank_and_advance
  # (new stop before old cancel; failures degrade, never crash).
  defp escalate(s, new_stop) do
    stop_res =
      s.venue.place_stop(%{side: side_of(-s.dir), qty: s.pos, trigger_price: new_stop, tag: :stop})

    s2 =
      case stop_res do
        {:ok, stop_ref} ->
          s.venue.cancel(s.stop_ref)
          if s.bank_ref, do: s.venue.cancel(s.bank_ref)
          %{s | stop: new_stop, stop_ref: stop_ref}

        {:error, reason} ->
          Logger.error(
            "ManagedTrade: 🛑 stop re-place on escalate FAILED — #{inspect(reason)}; old stop at $#{fmt(s.stop)} stays (still protective)"
          )

          s
      end

    next = Enum.at(s.tiers, s.tier + 1)
    tp2 = s.entry + s.dir * s.entry * next["tp2_pct"] / 100.0

    bank_ref =
      case s.venue.place_limit(%{
             side: side_of(-s.dir),
             qty: s.pos / 2,
             price: tp2,
             reduce_only: true,
             tag: {:bank, next["horizon"]}
           }) do
        {:ok, ref} ->
          ref

        {:error, reason} ->
          Logger.error(
            "ManagedTrade: bank limit on escalate failed — #{inspect(reason)}; continuing without a bank rung"
          )

          nil
      end

    Logger.info("ManagedTrade: escalate → #{next["horizon"]}   bank limit $#{fmt(tp2)}")

    s3 = %{s2 | bank_ref: bank_ref, tier: s.tier + 1, bars: 0}
    schedule_poll()
    {:noreply, s3}
  end

  # Missing stop on a walking trade — re-place it at the CURRENT
  # ratchet level. Called first in every poll until it succeeds.
  # Failure retries next poll with a loud UNPROTECTED warning; it
  # never gives up (giving up = the naked position the 2026-10-28
  # crash produced).
  defp replace_stop(%{stop: stop} = s) do
    case s.venue.place_stop(%{side: side_of(-s.dir), qty: s.pos, trigger_price: stop, tag: :stop}) do
      {:ok, ref} ->
        Logger.info("ManagedTrade: 🛡 stop recovered at $#{fmt(stop)}")
        schedule_poll()
        {:noreply, %{s | stop_ref: ref}}

      {:error, reason} ->
        Logger.error(
          "ManagedTrade: 🛑 stop re-place FAILED — #{inspect(reason)}; retrying next poll — POSITION UNPROTECTED"
        )

        schedule_poll()
        {:noreply, s}
    end
  end

  # === EXITS EXECUTE ===

  # Timeout/expiry: mark the exit pending; the next poll (immediately,
  # via send) cancels the resting orders and MARKETS out.
  defp exit_pending(s, ending) do
    send(self(), :poll)
    {:noreply, %{s | exit_pending: ending}}
  end

  # The exit protocol inverts the entry ordering: MARKET FIRST, then
  # cancel resting orders. If the market is rejected, the retry
  # happens with the stop (if it survived) still standing — exits
  # never cancel protection before the exit actually executes.
  defp attempt_exit(s, ending) do
    side = opp(side_of(s.dir))

    case s.venue.place_market(%{side: side, qty: s.pos, reduce_only: true, tag: :exit}) do
      {:ok, ref} ->
        # Exit order is ON — now clear the resting orders (harmless
        # if already gone; cancel translates already-gone to :ok).
        s.venue.cancel(s.stop_ref)
        if s.bank_ref, do: s.venue.cancel(s.bank_ref)

        fill = fill_price!(s.venue, ref, s.price)
        book_exit(s, fill, ending)

      {:error, reason} ->
        Logger.error("ManagedTrade: exit rejected — #{inspect(reason)}; retrying (stop still standing)")
        schedule_poll()
        {:noreply, s}
    end
  end

  # The terminal journal write. Ordering: fill → event → close. The
  # close records total = banked + exit-r; after this the process
  # exits :normal (:transient supervisor does not restart it — the
  # trade is DONE).
  defp book_exit(s, price, ending) do
    r = r_of(s, s.pos, price)
    total = s.banked + r

    Ledger.record_fill(s.key, :stop_exit, %{price: price, qty: s.pos})
    Ledger.record_event(s.key, ending, %{r: r, price: price})
    Ledger.close_trade(s.key, %{total_r: total, ending: ending, closed_at: DateTime.utc_now()})

    Logger.info(
      "ManagedTrade: ═ CLOSED — #{ending} @ $#{fmt(price)}  #{r_str(r)}R on the exit, TOTAL #{r_str(total)}R"
    )

    {:stop, :normal, s}
  end

  # === Helpers ===

  defp cur_tier(s), do: Enum.at(s.tiers, s.tier)

  defp floor_to_minute(dt) do
    sec = DateTime.to_unix(dt, :second)
    DateTime.from_unix!(sec - rem(sec, 60), :second)
  end

  # Multiples default to ×1.0 on nil/garbage — old broadcasts without
  # the fields trade at base Kelly rather than being rejected.
  defp mult(nil), do: 1.0
  defp mult(v) when is_number(v), do: v * 1.0
  defp mult(_), do: 1.0

  # nil ref (no order placed) is trivially not filled — keeps the
  # poll's cond clause simple for the no-bank-rung case.
  defp filled?(_venue, nil), do: false

  # ERROR VISIBILITY (post-2026-10-28): an order_status failure is
  # LOGGED, not swallowed. The old binary match? version turned
  # every poll error into a silent "not filled" and froze walks
  # with fills on the venue. Treat as not-filled this poll; the
  # warning makes a persistent error loop diagnosable.
  defp filled?(venue, ref) do
    case venue.order_status(ref) do
      {:ok, %{"filled" => filled}} ->
        filled

      {:error, reason} ->
        Logger.warning("ManagedTrade: order_status #{inspect(ref)} failed: #{inspect(reason)}")
        false
    end
  end

  # Fill price with fallback. fill_price nil (triggered-stop market
  # conversion, per the Venue contract) → the caller's reference
  # (trigger level for stops, broadcast entry for entries). The
  # fallback is always a defensible price; a fabricated 0.0 never
  # is (the -201.9R mis-booking taught this).
  defp fill_price!(venue, ref, fallback) do
    case venue.order_status(ref) do
      {:ok, %{"fill_price" => p}} when is_number(p) -> p * 1.0
      _ -> fallback
    end
  end

  defp side_of(1), do: :buy
  defp side_of(-1), do: :sell
  defp opp(:buy), do: :sell
  defp opp(:sell), do: :buy

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  # Float env parser with silent fallback — a typo'd KELLY_CAP must
  # degrade to the default, never crash the walk (same pattern as
  # TradeEngine.num/2).
  defp num(name, default) do
    case System.get_env(name) do
      nil -> default
      v ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> default
        end
    end
  end

  defp fmt(x), do: Float.round(x * 1.0, 2) |> :erlang.float_to_binary(decimals: 2)
  defp r_str(r), do: "#{if r < 0, do: "", else: "+"}#{Float.round(r, 3)}"
end

