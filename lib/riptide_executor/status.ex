defmodule RiptideExecutor.Status do
  @moduledoc """
  The one-command console view: every open trade with its live walk
  state, plus oracle health. RiptideExecutor.Status.print/0 answers
  "what is my system doing right now" in one command.

  ## What it reads — deliberately nothing but the locals

  Two sources only, both in-process:

    - Ledger.open_trades/0 — the DETS record of what SHOULD be open
    - ManagedTrade.state/1 — the LIVE walk state of what IS running
      (a GenServer call into each trade process)

  It never touches the venue. A trade whose process died but whose
  ledger record is open shows as 💀 NOT RUNNING — the divergence
  between the two sources IS the diagnosis, so hiding it by falling
  back to venue data would defeat the view's purpose. The 💀 line
  points the operator at Reconcile.run/0, which is the correct next
  action (close bookkeeping ghosts, flag real orphans loudly).

  ## Rendering contract (hard rule)

  Every renderer returns a FLAT LIST of strings; print/0 joins once
  with "\\n". No embedded newlines, no nested lists — embedded
  newlines broke the box spacing the first time this was written.
  Rows carry a LEFT BORDER ONLY ("║  text"): emoji are double-width
  and break right-border alignment differently per terminal, so the
  box deliberately has no right edge on content rows.

  ## Reading the icons

    - ⏳ — queued, awaiting the anchor bar close (zero orders sent)
    - 🔶 — walking, nothing banked yet (full risk still on)
    - 🟢 — walking with at least one tier banked (stop should be
      ratcheted; banked > 0 implies breakeven-or-better locked)
    - 💀 — ledger open, process gone → Reconcile

  The Oracle block is the health check for the heartbeat everything
  else depends on: pulses drive BOTH bar counting and the anchor
  verdict. ALIVE means failures < 3 and at least one successful
  fetch ever (see MarketFeed.status/0). A DOWN oracle means open
  trades are coasting on stale prices — treat as an incident.
  """

  # Logger is not actually used in this module today, but required
  # stays so future log lines don't repeat the
  # "Logger.warning/1 is undefined" compile-error class seen in the
  # sibling app.
  require Logger

  alias RiptideExecutor.{Ledger, ManagedTrade, MarketFeed}

  # Box width in characters — matches TrackRecord's box for visual
  # consistency when both views are printed side by side.
  @width 58

  @doc """
  Structured status: open trades + live states + oracle health.

  Returns:
      %{
        oracle: MarketFeed.status() map (+ :alive? boolean),
        open_trades: [
          %{
            key: dedupe triple,
            opened_at: DateTime | nil,
            kind: :ladder | ...,
            running?: boolean — a live ManagedTrade process exists,
            state: walk state map | nil (nil ⇔ running? false)
          }
        ]
      }

  running? is the join between the two sources of truth: the ledger
  says the trade exists, the registry says whether anyone is
  managing it. state is nil exactly when the process is gone —
  callers can rely on that pairing.
  """
  def status do
    trades =
      Ledger.open_trades()
      |> Enum.map(fn key ->
        trade = Ledger.get_trade(key) || %{}

        # ManagedTrade.state/1 does the registry lookup + GenServer
        # call with a 5s timeout and catches exits, so a trade dying
        # mid-call reads as {:error, _} → nil, never a crash of the
        # status view itself.
        state =
          case ManagedTrade.state(key) do
            {:ok, st} -> st
            _ -> nil
          end

        %{
          key: key,
          opened_at: trade[:opened_at],
          kind: trade[:kind],
          running?: state != nil,
          state: state
        }
      end)

    %{oracle: MarketFeed.status(), open_trades: trades}
  end

  @doc """
  Console dashboard — boxed, spaced, iconed. Side-effect only;
  always returns :ok. Composition: header box + oracle block +
  trade section, every piece a flat line list per the rendering
  contract. The OPEN TRADES section header carries the count, and
  the empty case renders an explicit "all capital idle" line rather
  than an empty box — an empty section must never look like a bug.
  """
  def print do
    st = status()

    # Header + oracle. The oracle lines are 3 rows in both alive and
    # down states so the box height doesn't jump between states.
    lines =
      [top(), row("🎛️  RIPTIDE EXECUTOR"), mid(), blank()] ++
        oracle_lines(st.oracle) ++
        [blank()]

    lines =
      if st.open_trades == [] do
        lines ++
          [
            section_top(),
            section_title("OPEN TRADES"),
            section_rule(),
            row("   ✨ none — all capital idle"),
            bottom()
          ]
      else
        lines ++
          [
            section_top(),
            section_title("OPEN TRADES (#{length(st.open_trades)})"),
            section_rule()
          ] ++
          # flat_map: each trade contributes 1-5 lines, all flattened
          # into the single joinable list. Running trades get a
          # progress bar appended after their stat lines.
          Enum.flat_map(st.open_trades, fn t ->
            case t.running? do
              true -> trade_line(t) ++ [tier_line(t.state)]
              false -> trade_line(t)
            end
          end) ++ [bottom()]
      end

    IO.puts(Enum.join(lines, "\n"))
    :ok
  end

  # === Oracle rendering — each entry is its own line ===
  # (per the contract: no embedded newlines anywhere)

  # ALIVE: freshness is the real signal — age in seconds since the
  # last successful 1m bar fetch. A "healthy" oracle whose last_ok
  # is minutes old is lying about the market.
  defp oracle_lines(%{alive?: true} = o) do
    age = o.last_ok && DateTime.diff(DateTime.utc_now(), o.last_ok, :second)

    [
      row("Oracle   ✅ ALIVE"),
      row("   last bar #{o.last_ok && DateTime.to_iso8601(o.last_ok)} (#{age}s ago)"),
      row("   close    $#{o.last_price && fmt_p(o.last_price)}")
    ]
  end

  # DOWN: consecutive-failure count first (how broken), then last
  # known good bar and price (how stale the walk's picture is).
  defp oracle_lines(%{alive?: false} = o) do
    [
      row("Oracle   🛑 DOWN — #{o.failures} consecutive failures"),
      row("   last ok  #{o.last_ok && DateTime.to_iso8601(o.last_ok)}"),
      row("   last px  #{o.last_price && "$" <> fmt_p(o.last_price)}")
    ]
  end

  # === Trade rendering — flat lists of lines ===

  # Queued trade: one line. The walk has sent nothing to the venue —
  # the only thing it's waiting on is time (anchor + 60s).
  defp trade_line(%{running?: true, state: %{phase: :awaiting}} = t) do
    ["║  ⏳ #{fmt_key(t.state.key)}   queued — awaiting anchor bar close"]
  end

  # Walking trade: the four numbers an operator glances for — which
  # tier, how far through its bar budget, how much risk is left
  # (pos), how much is locked (banked), and the three prices that
  # define the trade (entry / mark / stop). kind is shown because a
  # non-:ladder kind in the ledger would mean an unexpected trade
  # class — visible by design.
  defp trade_line(%{running?: true, state: s, kind: kind}) do
    icon = if s.banked > 0.0, do: "🟢", else: "🔶"

    [
      "║  #{icon} #{fmt_key(s.key)}  [#{kind || :ladder}]",
      "║     tier #{s.tier + 1}  #{s.horizon}   bar #{s.bars}/#{s.tier_bars}",
      "║     pos  #{Float.round(s.pos * 1.0, 4)} BTC   banked #{r(s.banked)}R",
      "║     entry $#{fmt_p(s.entry)}   price $#{fmt_p(s.price)}   stop $#{fmt_p(s.stop)}"
    ]
  end

  # The divergence case: ledger open, process dead. This is the
  # line that caught the 2026-10-28 nonce crash — never remove it.
  # The action pointer is literal: Reconcile.run/0 is the tool.
  defp trade_line(%{running?: false, key: key, opened_at: opened}) do
    [
      "║  💀 #{fmt_key(key)}   NOT RUNNING",
      "║     opened #{opened && DateTime.to_iso8601(opened)}",
      "║     → RiptideExecutor.Reconcile.run()"
    ]
  end

  # 20-cell progress bar of the CURRENT tier's bar budget, clamped
  # at 100% (a stall over budget renders full, not overflowing).
  # Integer math only: pct is truncated first, then scaled to 20
  # cells — never more than 20 █, never negative ░.
  defp tier_line(s) do
    pct =
      if s.tier_bars > 0,
        do: s.bars / s.tier_bars * 100 |> min(100) |> trunc(),
        else: 100

    filled = div(pct * 20, 100)

    "║     [" <>
      String.duplicate("█", filled) <>
      String.duplicate("░", 20 - filled) <>
      "]"
  end

  # === Box helpers ===

  defp top, do: "╔#{bar()}╗"
  defp mid, do: "╠#{bar()}╣"
  defp bottom, do: "╚#{bar()}╝"
  defp bar, do: String.duplicate("═", @width)

  defp section_top, do: "╠#{bar()}╣"
  defp section_title(title), do: "║  ▸ #{title}"
  defp section_rule, do: "╟#{String.duplicate("─", @width)}╢"

  # Left border only — emoji are double-width and break right-border
  # alignment across terminals.
  defp row(text), do: "║  #{text}"
  defp blank, do: "║"

  # Keys are the dedupe triple; display shows just the anchor
  # timestamp (symbol/market are constants in this deployment).
  defp fmt_key({_s, _m, ts}) when is_binary(ts), do: ts
  defp fmt_key(_), do: "?"

  defp fmt_p(p), do: Float.round(p * 1.0, 2) |> :erlang.float_to_binary(decimals: 2)

  # Signed R formatter — same convention as TrackRecord.r/1: "+"
  # prefix for non-negatives, three decimals.
  defp r(x), do: "#{if x < 0, do: "", else: "+"}#{Float.round(x * 1.0, 3)}"
end

