defmodule RiptideExecutor.StubOracle do
  @table :stub_oracle

  def ensure do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :named_table, :public])
      _ -> :ok
    end
  end

  def set(close), do: :ets.insert(@table, {:close, close})
  def clear, do: :ets.delete_all_objects(@table)

  def close_at_bar(_ts) do
    case :ets.lookup(@table, :close) do
      [{_, c}] -> c
      [] -> nil
    end
  end
end

defmodule RiptideExecutor.ManagedTradeTest do
  use ExUnit.Case, async: false

  alias RiptideExecutor.{FakeVenue, Ledger, ManagedTrade, StubOracle}

  # Geometry: entry 100, tier-1 stop 1% → 1R = $1.00 of price. Bankroll
  # 10 × kelly 0.2 ÷ risk 1.0 = 2.0 BTC initial position (unabsorbed).
  # ABSORBED → close_mult ×0.5 → kelly_eff 0.1 → qty 1.0. Tiers 2/2.
  @entry 100.0
  @tables ~w(exec_trades exec_fills exec_events exec_seen)a

  defp ladder(opts \\ []) do
    bearish? = Keyword.get(opts, :bearish?, false)
    anchor = Keyword.get(opts, :anchor) || unique_future_minute()

    %{
      "symbol" => "BTCUSDT",
      "market_type" => "futures",
      "anchor_ts" => DateTime.to_iso8601(anchor),
      "direction" => if(bearish?, do: "bearish", else: "bullish"),
      "entry_price" => @entry,
      "cdf_vpin" => 0.97,
      "kelly_fraction" => 0.2,
      "risk_anchor_horizon" => "3h",
      "close_mult" => Keyword.get(opts, :close_mult, 1.0),
      "quiet_mult" => Keyword.get(opts, :quiet_mult, 1.0),
      "tiers" => [
        %{
          "horizon" => "3h",
          "bars" => 2,
          "sl_pct" => 1.0,
          "tp2_pct" => 2.0,
          "r_mean" => 0.16,
          "r_std" => 0.9,
          "kelly_fraction" => 0.2
        },
        %{
          "horizon" => "6h",
          "bars" => 2,
          "sl_pct" => 1.0,
          "tp2_pct" => 3.0,
          "r_mean" => 0.16,
          "r_std" => 0.9,
          "kelly_fraction" => 0.2
        }
      ]
    }
  end

  defp late_ladder(opts \\ []) do
    ts =
      minute_now()
      |> DateTime.add(-300 - rem(System.unique_integer([:positive]), 1_000_000) * 3600, :second)

    ladder(Keyword.merge(opts, anchor: ts))
  end

  defp unique_future_minute do
    DateTime.add(
      minute_now(),
      rem(System.unique_integer([:positive]), 1_000_000) * 60 + 60,
      :second
    )
  end

  defp minute_now, do: DateTime.utc_now() |> floor_to_minute()

  defp floor_to_minute(dt) do
    sec = DateTime.to_unix(dt, :second)
    DateTime.from_unix!(sec - rem(sec, 60), :second)
  end

  setup do
    System.put_env("MAX_POSITION_BTC", "100")
    System.put_env("KELLY_CAP", "1.0")

    ensure_ledger()
    ensure_fake_venue()
    ensure_registry()
    StubOracle.ensure()
    StubOracle.clear()

    FakeVenue.reset()
    FakeVenue.set_price(@entry)

    on_exit(fn ->
      System.delete_env("MAX_POSITION_BTC")
      System.delete_env("KELLY_CAP")
    end)

    :ok
  end

  # ALWAYS wipe — DETS persists across mix test runs; a stale fill
  # from a prior run under a colliding key poisons assertions.

  defp ensure_ledger do
    cond do
      Process.whereis(Ledger) != nil and
          Enum.all?(@tables, &(:dets.info(&1) != :undefined)) ->
        :ok

      Process.whereis(Ledger) != nil ->
        GenServer.stop(Ledger)
        {:ok, _} = Ledger.start_link(dir: "priv/test_ledger")

      true ->
        {:ok, _} = Ledger.start_link(dir: "priv/test_ledger")
    end

    wipe_tables()
  end

  defp wipe_tables do
    Enum.each(@tables, fn t ->
      :dets.delete_all_objects(t)
      :dets.sync(t)
    end)
  end

  defp ensure_fake_venue do
    case Process.whereis(FakeVenue) do
      nil -> {:ok, _} = FakeVenue.start_link([])
      _pid -> :ok
    end
  end

  defp ensure_registry do
    case Process.whereis(RiptideExecutor.TradeRegistry) do
      nil -> {:ok, _} = Registry.start_link(keys: :unique, name: RiptideExecutor.TradeRegistry)
      _pid -> :ok
    end

    case Process.whereis(RiptideExecutor.PulseRegistry) do
      nil -> {:ok, _} = Registry.start_link(keys: :duplicate, name: RiptideExecutor.PulseRegistry)
      _pid -> :ok
    end
  end

  # ============================================================
  # Drivers
  # ============================================================

  defp open_trade(ladder, bankroll \\ 10.0) do
    key = {ladder["symbol"], ladder["market_type"], ladder["anchor_ts"]}
    :ok = Ledger.record_trade(key, %{pred: ladder, source: :test, kind: :ladder})
    {:ok, pid} = ManagedTrade.start_link({FakeVenue, StubOracle, key, ladder, bankroll})

    wait_until(fn ->
      trade = Ledger.get_trade(key)
      trade != nil and (trade.status == :closed or managed?(key))
    end)

    {key, pid, parse_anchor(ladder)}
  end

  defp managed?(key) do
    case ManagedTrade.state(key) do
      {:ok, %{phase: p}} when p in [:awaiting, :walking] -> true
      _ -> false
    end
  end

  defp parse_anchor(ladder) do
    {:ok, dt, _} = DateTime.from_iso8601(ladder["anchor_ts"])
    dt
  end

  defp wait_until(fun, tries \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.(), do: :ok, else: Process.sleep(20) && wait_until(fun, tries - 1)
  end

  defp pulse(pid, bar_ts, price) do
    FakeVenue.set_price(price)
    send(pid, {:pulse, bar_ts, price})
    settle(pid)
  end

  defp anchor_close_pulse(pid, anchor, price),
    do: pulse(pid, DateTime.add(anchor, 60, :second), price)

  defp bar_pulse(pid, anchor, n, price),
    do: pulse(pid, DateTime.add(anchor, 60 + n * 60, :second), price)

  defp poll(pid, price) do
    FakeVenue.set_price(price)
    send(pid, :poll)
    settle(pid)
  end

  # A driven step may LEGITIMATELY end the walk (stop exit, final
  # expiry) — :exited is the expected return. Tests needing the walk
  # to CONTINUE wrap the step with live/1.
  defp settle(pid) do
    :sys.get_state(pid)
  catch
    :exit, _ -> :exited
  end

  defp live(%{} = st), do: st

  defp live(:exited),
    do: flunk("walk exited unexpectedly during a step that should continue")

  defp event_names(key), do: Ledger.event_log(key) |> Enum.map(&elem(&1, 0))

  defp closed_trade(key) do
    wait_until(fn -> (Ledger.get_trade(key) || %{})[:status] == :closed end)
    Ledger.get_trade(key)
  end

  # ============================================================
  # 1. The queue: zero orders until the anchor candle closes
  # ============================================================

  test "queued: nothing placed before the anchor bar closes; enters after" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    assert {:ok, %{phase: :awaiting}} = ManagedTrade.state(key)
    assert Ledger.fills(key) == []
    assert Process.alive?(pid)

    st = live(anchor_close_pulse(pid, anchor, 100.0))

    assert st.phase == :walking
    assert [%{price: 100.0, qty: 2.0}] = Ledger.fills(key)
  end

  # ============================================================
  # 2. The verdict — a SIZING input, never a skip
  # ============================================================

  test "long: anchor closes BELOW entry → ABSORBED → enters at HALF size" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 99.5))

    # absorbed → close_mult ×0.5 → kelly_eff 0.1 → qty = 10 × 0.1 / 1.0
    assert st.phase == :walking
    assert_in_delta st.pos, 1.0, 1.0e-9

    trade = Ledger.get_trade(key)
    assert trade.absorbed == true
    assert trade.close_mult == 0.5
    # risk recomputed from the ACTUAL fill (99.50): 99.5 × 1% = 0.995
    assert_in_delta trade.capital_risked, 0.995, 1.0e-9
    assert [%{price: 99.5, qty: 1.0}] = Ledger.fills(key)
    assert Process.alive?(pid)
  end

  test "short: anchor closes ABOVE entry → ABSORBED → enters at HALF size" do
    ladder = ladder(bearish?: true)
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 100.5))

    assert st.phase == :walking
    assert_in_delta st.pos, 1.0, 1.0e-9
    assert Ledger.get_trade(key).absorbed == true
  end

  test "short: anchor closes in favor → enters FULL size, stop ABOVE the fill" do
    ladder = ladder(bearish?: true)
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 99.5))

    assert st.phase == :walking
    assert_in_delta st.pos, 2.0, 1.0e-9
    assert st.entry == 99.5
    assert_in_delta st.risk, 0.995, 1.0e-9
    assert_in_delta st.stop, 100.495, 1.0e-9
    assert Ledger.get_trade(key).absorbed == false
  end

  test "boundary: anchor close exactly at entry is NOT absorbed" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 100.0))
    assert st.phase == :walking
    assert_in_delta st.pos, 2.0, 1.0e-9
    assert Ledger.get_trade(key).absorbed == false
  end

  test "late registration + oracle says absorbed → HALF size, no pulses needed" do
    StubOracle.set(99.5)
    ladder = late_ladder()
    {key, _pid, _anchor} = open_trade(ladder)

    wait_until(fn -> Ledger.fills(key) != [] end)
    assert [%{price: 100.0, qty: 1.0}] = Ledger.fills(key)
    assert Ledger.get_trade(key).absorbed == true
  end

  test "late registration + oracle unreachable → FULL size at the broadcast multiple" do
    StubOracle.set(nil)
    ladder = late_ladder()
    {key, _pid, _anchor} = open_trade(ladder)

    wait_until(fn -> Ledger.fills(key) != [] end)
    assert [%{price: 100.0, qty: 2.0}] = Ledger.fills(key)
    assert Ledger.get_trade(key).absorbed == nil
  end

  test "late registration + oracle says in favor → FULL size at market" do
    StubOracle.set(100.2)
    ladder = late_ladder()
    {key, _pid, _anchor} = open_trade(ladder)

    wait_until(fn -> Ledger.fills(key) != [] end)
    assert [%{price: 100.0, qty: 2.0}] = Ledger.fills(key)
    assert Ledger.get_trade(key).absorbed == false
  end

  # ============================================================
  # 3. The multiples — capital scaled by close × quiet
  # ============================================================

  test "multiples scale the position, capped by KELLY_CAP" do
    System.put_env("KELLY_CAP", "1.0")
    ladder = ladder(close_mult: 2.0, quiet_mult: 3.0)
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 100.0))

    # not absorbed → broadcast multiples: kelly_eff = min(0.2 × 6, 1.0)
    assert_in_delta st.pos, 10.0, 1.0e-9

    trade = Ledger.get_trade(key)
    assert trade.close_mult == 2.0
    assert trade.quiet_mult == 3.0
    assert_in_delta trade.kelly_eff, 1.0, 1.0e-9
    assert_in_delta trade.capital_risked, 10.0, 1.0e-9
  end

  test "multiples below the cap apply exactly: 1.5 × 2.0 → kelly 0.6" do
    System.put_env("KELLY_CAP", "1.0")
    ladder = ladder(close_mult: 1.5, quiet_mult: 2.0)
    {key, pid, anchor} = open_trade(ladder)

    st = live(anchor_close_pulse(pid, anchor, 100.0))

    assert_in_delta st.pos, 6.0, 1.0e-9
    assert_in_delta Ledger.get_trade(key).kelly_eff, 0.6, 1.0e-9
  end

  test "missing multiples default to x1 — old broadcasts still trade" do
    System.put_env("KELLY_CAP", "1.0")

    plain =
      ladder()
      |> Map.delete("close_mult")
      |> Map.delete("quiet_mult")

    {key, pid, anchor} = open_trade(plain)

    st = live(anchor_close_pulse(pid, anchor, 100.0))
    assert_in_delta st.pos, 2.0, 1.0e-9
    assert_in_delta Ledger.get_trade(key).kelly_eff, 0.2, 1.0e-9
  end

  # ============================================================
  # 4. The certified walk — hand-derived, pinned
  # ============================================================

  test "bank at tier-1 tp2: half off, +1R, stop ratchets, escalates" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    anchor_close_pulse(pid, anchor, 100.0)
    st = live(poll(pid, 102.5))

    assert st.tier == 1
    assert st.pos == 1.0
    assert st.stop == 101.0
    assert st.banked == 1.0
    assert [{:bank, %{tier: "3h", r: 1.0}}] = Ledger.event_log(key)
  end

  test "full walk to final expiry: market exit executes, +1.8R, event sequence" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    anchor_close_pulse(pid, anchor, 100.0)
    poll(pid, 102.5)
    bar_pulse(pid, anchor, 1, 101.6)

    # bar 2 timeout sets the exit; the queued poll executes the market order
    bar_pulse(pid, anchor, 2, 101.6)
    wait_until(fn -> not Process.alive?(pid) end)

    trade = closed_trade(key)

    assert_in_delta trade.total_r, 1.8, 1.0e-9
    assert trade.ending == :final_expiry
    assert event_names(key) == [:bank, :timeout_escalate, :final_expiry]
    refute key in Ledger.open_trades()

    # the exit was EXECUTED: a :stop_exit fill at the exit price
    prices = Enum.map(Ledger.fills(key), & &1.price)
    assert 101.6 in prices
  end

  test "straight stop before any bank: exactly -1R at the stop price" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    anchor_close_pulse(pid, anchor, 100.0)
    bar_pulse(pid, anchor, 1, 99.0)

    assert poll(pid, 99.0) == :exited

    trade = closed_trade(key)

    assert trade.total_r == -1.0
    assert trade.ending == :stop
    assert event_names(key) == [:stop]

    prices = Enum.map(Ledger.fills(key), & &1.price)
    assert 100.0 in prices
    assert 99.0 in prices
  end

  test "stop after bank: books at the ratcheted stop, stays positive" do
    ladder = ladder()
    {key, pid, anchor} = open_trade(ladder)

    anchor_close_pulse(pid, anchor, 100.0)
    poll(pid, 102.5)
    bar_pulse(pid, anchor, 1, 100.5)

    assert poll(pid, 100.5) == :exited

    trade = closed_trade(key)

    assert trade.total_r == 1.5
    assert trade.ending == :stop
    assert event_names(key) == [:bank, :stop]
  end
 
  # ============================================================
  # 5. Reporting: multiples + capital + dollars, no ambiguity
  # ============================================================

  test "the trade record carries multiples, capital, and dollar P&L" do
    # TrackRecord reads ALL closed trades in DETS — sibling tests in the
    # same run legitimately leave closed trades behind. Assert DELTAS,
    # not absolute counts.
    before = RiptideExecutor.TrackRecord.summary()
    b_trades = before[:trades] || 0
    b_risked = before[:capital_risked] || 0.0
    b_pnl = before[:pnl_usd] || 0.0

    ladder = ladder(close_mult: 2.0, quiet_mult: 1.0)
    {key, pid, anchor} = open_trade(ladder)

    anchor_close_pulse(pid, anchor, 100.0)
    poll(pid, 102.5)
    bar_pulse(pid, anchor, 1, 101.6)

    # bar 2 timeout sets the exit; the queued poll executes the market order
    bar_pulse(pid, anchor, 2, 101.6)
    wait_until(fn -> not Process.alive?(pid) end)

    trade = closed_trade(key)

    assert trade.close_mult == 2.0
    assert trade.quiet_mult == 1.0
    assert_in_delta trade.kelly_eff, 0.4, 1.0e-9
    assert_in_delta trade.capital_risked, 4.0, 1.0e-9
    assert trade.absorbed == false

    assert_in_delta trade.total_r * trade.capital_risked, 7.2, 1.0e-9

    after_ = RiptideExecutor.TrackRecord.summary()

    assert after_.trades - b_trades == 1
    assert_in_delta after_.capital_risked - b_risked, 4.0, 1.0e-9
    assert_in_delta after_.pnl_usd - b_pnl, 7.2, 1.0e-9
  end

  test "deadzone flow (|ofi| <= 0.05) → skipped, no orders" do
    ladder = ladder() |> Map.put("ofi", 0.03)
    {key, pid, anchor} = open_trade(ladder)

    assert anchor_close_pulse(pid, anchor, 100.0) == :exited

    trade = closed_trade(key)
    assert trade.ending == :deadzone_skip
    assert Ledger.fills(key) == []
  end
end
