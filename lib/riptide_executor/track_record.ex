defmodule RiptideExecutor.TrackRecord do
  @moduledoc """
  The scoreboard: sums up all trading activity recorded in the DETS
  ledger. summary/0 returns the structured numbers; print/0 renders
  the console table. Dollars = R × capital_risked per trade — the
  fund's accounting, no ambiguity.

  ## What this module is for

  The executor's unit of account is R, not dollars: a trade's outcome
  is measured against what it RISKED, so a +1R from a $4 risk is
  worth exactly as much as a +1R from a $400 risk. That single
  convention makes every trade comparable across wildly different
  sizes, venues, and regimes. TrackRecord is where R turns back into
  money: dollars = total_r × capital_risked per trade, summed. Both
  numbers are shown because both are true — R for the edge, dollars
  for the account.

  ## What it reads, and what it deliberately does NOT

  Reads ONLY closed trades from the Ledger (:exec_trades). It never
  touches the venue, never looks at fills directly, never computes
  anything from prices. If the ledger is wrong (mis-booked exits,
  phantom closes), the scoreboard faithfully reports the wrong
  numbers — that is correct behavior: a scoreboard that "fixes" its
  input would hide ledger corruption. Ledger integrity is Ledger +
  Reconcile's job; TrackRecord trusts its journal and renders.

  ## Accounting conventions, pinned

    - WIN  — total_r > 0.0    LOSS — total_r < 0.0
    - SCRATCH — exactly 0.0 (e.g. dry_run, deadzone_skip, orphans
      closed at zero). Scratches count in n but carry no P&L.
    - Trades missing capital_risked (dry_run, deadzone) contribute
      zero to the dollar sums but their full R to the R sums. This
      is deliberate: R-only endings (dry runs) are information about
      the signal, not about money.
    - by_day is limited to the last 7 ISO dates WITH closes — not a
      rolling calendar window. Quiet days simply don't appear.
  """

  require Logger

  alias RiptideExecutor.Ledger

  # Box width in characters — matches Status.print's box so the two
  # console views are visually consistent side by side.
  @width 58

  @doc """
  Full structured track record over closed trades.

  Returns %{trades: 0} when nothing has closed yet — callers must
  handle that shape explicitly (print/0 does; a future JSON API
  endpoint would too). All other keys:

    - trades / total_r / mean_r — count and R-sum over every closed
      trade in the ledger, chronological by close time
    - wins / losses / scratches / win_rate — the strict-sign split
      described in the moduledoc
    - best / worst — {total_r, key} of the extremes
    - by_ending — grouped by the walk's terminal event (:stop,
      :final_expiry, :dry_run, :deadzone_skip, ...): n, total R,
      mean R, win rate per ending class. THE diagnostic view for
      "which exit path makes or loses the money".
    - by_day — last 7 close-dates → R sum
    - avg_hold_min — mean open→close duration in minutes; nil when
      unknowable (no timestamps)
    - capital_risked / pnl_usd — the dollar view: Σ risked, and
      Σ (r × risked)

  Sort key is closed_at falling back to opened_at, so records
  missing a close timestamp still sort deterministically rather
  than vanishing from the summary.
  """
  def summary do
    closed =
      Ledger.trade_keys()
      |> Enum.map(fn key -> {key, Ledger.get_trade(key)} end)
      |> Enum.filter(fn {_k, t} -> t && t.status == :closed end)
      |> Enum.sort_by(fn {_k, t} -> DateTime.to_unix(t.closed_at || t.opened_at) end)

    n = length(closed)

    if n == 0 do
      %{trades: 0}
    else
      rs = Enum.map(closed, fn {_k, t} -> t.total_r * 1.0 end)
      total = Enum.sum(rs)
      wins = Enum.count(rs, &(&1 > 0.0))
      losses = Enum.count(rs, &(&1 < 0.0))
      scratches = n - wins - losses

      ranked = Enum.map(closed, fn {k, t} -> {t.total_r, k} end)
      best = Enum.max_by(ranked, fn {r, _} -> r end)
      worst = Enum.min_by(ranked, fn {r, _} -> r end)

      durations =
        closed
        |> Enum.flat_map(fn {_k, t} ->
          if t[:closed_at] && t[:opened_at] do
            [DateTime.diff(t.closed_at, t.opened_at, :second) / 60.0]
          else
            []
          end
        end)

      avg_hold =
        if durations == [] do
          nil
        else
          Enum.sum(durations) / length(durations)
        end

      risked =
        Enum.map(closed, fn {_k, t} ->
          if is_number(t[:capital_risked]), do: t.capital_risked * 1.0, else: 0.0
        end)

      capital_risked_total = Enum.sum(risked)

      # Zip pairs r with ITS OWN capital_risked — order is guaranteed
      # because both lists map over the same sorted `closed` list.
      # r × capital_risked IS the dollar P&L by the fund's definition
      # (total_r is already position-fraction-normalized, so this is
      # exact, not approximate).
      pnl_usd_total =
        Enum.zip(rs, risked)
        |> Enum.map(fn {r, c} -> r * c end)
        |> Enum.sum()

      %{
        trades: n,
        total_r: total,
        mean_r: total / n,
        wins: wins,
        losses: losses,
        scratches: scratches,
        win_rate: wins / n * 100.0,
        best: best,
        worst: worst,
        by_ending: by_ending(closed),
        by_day: by_day(closed),
        avg_hold_min: avg_hold,
        capital_risked: capital_risked_total,
        pnl_usd: pnl_usd_total
      }
    end
  end

  @doc """
  Console scoreboard — boxed, spaced, iconed. Reads summary/0; the
  rendering contract matches Status: flat lists of lines, joined
  once, left-border-only rows (emoji are double-width and break
  right-border alignment across terminals).

  Always returns :ok (IO side-effect only) — suitable for direct
  IEx invocation.
  """
  def print do
    s = summary()

    if s.trades == 0 do
      IO.puts("Track record: no closed trades yet.")
      :ok
    else
      out = [
        top(),
        row("📊 TRACK RECORD"),
        mid(),
        blank(),
        field("Trades", "#{s.trades}"),
        field("Total R", r(s.total_r), color_r: s.total_r),
        field("Mean R", r(s.mean_r), color_r: s.mean_r),
        field("💵 Capital risked", "$#{usd(s.capital_risked)}"),
        field("💰 P&L", "$#{usd(s.pnl_usd)}", color_r: s.pnl_usd),
        blank(),
        field("✅ Wins", "#{s.wins}"),
        field("❌ Losses", "#{s.losses}"), 
        field("⚪ Scratches", "#{s.scratches}"),
        field("🎯 Win rate", "#{Float.round(s.win_rate, 1)}%"),
        blank(),
        field("🏆 Best", "#{r(elem(s.best, 0))}   #{fmt_key(elem(s.best, 1))}"),
        field("💥 Worst", "#{r(elem(s.worst, 0))}   #{fmt_key(elem(s.worst, 1))}"),
        field("⏱️  Avg hold", hold_str(s.avg_hold_min)),
        blank()
      ]

      IO.puts(Enum.join(out, "\n"))

      # BY ENDING — the per-exit-path scoreboard. Sorted by ending
      # name for stable output.
      section("BY ENDING")

      Enum.each(Enum.sort(s.by_ending), fn {ending, stats} ->
        IO.puts(
          "║   #{String.pad_trailing(Atom.to_string(ending), 14)}" <>
            "n=#{String.pad_leading("#{stats.n}", 4)}   " <>
            "R #{String.pad_leading(r(stats.r), 9)}   " <>
            "win #{String.pad_leading("#{Float.round(stats.win_rate, 1)}%", 6)}"
        )
      end)

      blank_line()
      section("LAST 7 DAYS")

      Enum.each(Enum.sort(s.by_day), fn {date, r} ->
        IO.puts("║   #{String.pad_trailing(date, 14)}#{String.pad_leading(r(r), 9)}")
      end)

      IO.puts(bottom())
      :ok
    end
  end

  # === Box helpers ===

  defp top, do: "╔#{bar()}╗"
  defp mid, do: "╠#{bar()}╣"
  defp bottom, do: "╚#{bar()}╝"
  defp bar, do: String.duplicate("═", @width)

  # Inline section rendering: writes its own border lines rather than
  # building a list, because it appears AFTER the main box is printed
  # (ordering with IO side effects, not data).
  defp section(title) do
    IO.puts("╠#{bar()}╣")
    IO.puts("║  ▸ #{title}")
    IO.puts("╟#{String.duplicate("─", @width)}╢")
  end

  defp row(text), do: "║  #{text}"
  defp blank, do: "║"
  defp blank_line, do: IO.puts("║")

  # `color_r` option adds a ▲/▼ direction mark for money-ish values.
  # Pure display — the sign is already IN the number.
  defp field(label, value, opts \\ []) do
    mark =
      case opts[:color_r] do
        v when is_number(v) and v > 0 -> "▲"
        v when is_number(v) and v < 0 -> "▼"
        _ -> " "
      end

    "║   #{String.pad_trailing(label, 18)}#{mark} #{value}"
  end

  # === Private ===

  # Group closed trades by terminal event. t[:ending] may be absent
  # on very old or foreign records — those pool under :unknown rather
  # than being dropped. Every record counts somewhere.
  defp by_ending(closed) do
    closed
    |> Enum.group_by(fn {_k, t} -> t[:ending] || :unknown end)
    |> Map.new(fn {ending, trades} ->
      rs = Enum.map(trades, fn {_k, t} -> t.total_r * 1.0 end)
      n = length(rs)
      total = Enum.sum(rs)
      wins = Enum.count(rs, &(&1 > 0.0))

      {ending,
       %{
         n: n,
         r: total,
         mean_r: total / n,
         win_rate: if(n > 0, do: wins / n * 100.0, else: 0.0)
       }}
    end)
  end

  # Group by ISO close-date, sum R per day, keep the LAST 7 dates
  # that had closes (sorted ascending, take -7). Days with zero
  # closes are omitted by construction — this is a "last 7 ACTIVE
  # days" view, not a calendar window.
  defp by_day(closed) do
    closed
    |> Enum.reject(fn {_k, t} -> is_nil(t[:closed_at]) end)
    |> Enum.group_by(fn {_k, t} -> Date.to_iso8601(DateTime.to_date(t.closed_at)) end)
    |> Map.new(fn {date, trades} ->
      {date, trades |> Enum.map(fn {_k, t} -> t.total_r end) |> Enum.sum()}
    end)
    |> Enum.sort_by(fn {d, _} -> d end)
    |> Enum.take(-7)
    |> Map.new()
  end

  # Keys are the dedupe triple {symbol, market_type, anchor_ts}.
  # Display shows just the anchor timestamp — symbol/market are
  # constants in this deployment (BTCUSDT futures).
  defp fmt_key({_s, _m, ts}) when is_binary(ts), do: ts
  defp fmt_key(_), do: "?"
  defp hold_str(nil), do: "n/a"
  defp hold_str(min), do: "#{Float.round(min, 1)} min"

  defp usd(x), do: Float.round(x * 1.0, 2) |> :erlang.float_to_binary(decimals: 2)

  # Signed R formatter: "+" only for non-negatives, negatives carry
  # their own "-". Three decimals — R is read at that precision.
  defp r(x), do: "#{if x < 0, do: "", else: "+"}#{Float.round(x * 1.0, 3)}"
end

