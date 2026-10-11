defmodule RiptideExecutor.TradeEngine do
  @moduledoc """
  Turns a prediction into KuCoin orders.

  THIS CHUNK: dry-run logging only. No order is ever sent. The log
  line is the full intended trade — review these while dry-running.
  """

  require Logger

  def execute(pred) do
    if dry_run?() do
      Logger.info("""
      ═══ DRY RUN — WOULD TRADE ═══
      #{pred["direction"]} #{pred["market_type"]} @ $#{pred["entry_price"]}
      anchor: #{pred["anchor_ts"]}
      SL:  #{pred["params"]["sl_pct"]}%
      TP1: #{pred["params"]["tp1_pct"]}% (half off, stop to breakeven)
      TP2: #{pred["params"]["tp2_pct"]}% (remainder)
      timeout: #{pred["params"]["max_bars"]} min
      Kelly: #{pred["kelly_fraction"]}  conf: #{pred["confidence"]}
      Expected R: #{pred["r_mean"]} ± #{pred["r_std"]}
      ═════════════════════════════
      """)
    else
      Logger.warning("TradeEngine: live order placement not built yet — refusing to trade")
    end
  end

  defp dry_run?, do: System.get_env("DRY_RUN", "true") == "true"
end
