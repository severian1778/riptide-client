defmodule RiptideExecutor.Oracle do
  @moduledoc """
  Historical bar lookups for the absorption check.

  ## Why this exists — the late-registration problem

  A trade's anchor verdict needs the CLOSE of the 1-minute anchor
  candle. A trade that registered BEFORE the anchor closed learns it
  for free: the very next MarketFeed pulse at anchor+60s carries the
  just-closed bar's price. But a trade registered AFTER the anchor
  closed (backfill-fresh — the ladder fired while this executor was
  down, within Feed's 120s freshness window) has missed that pulse
  and can never get the anchor close from the live feed again. The
  pulse stream is forward-only; history is not in it.

  The Oracle is the history service for exactly that case: it fetches
  the 1m bar that OPENED at anchor_ts from Binance Futures and
  returns its close. ManagedTrade's late-registration path calls
  this once at startup, best-effort, and proceeds on the verdict:

    - Oracle returns a number → normal verdict (absorbed → ×0.5
      sizing, in-favor → full size)
    - Oracle returns nil → trade proceeds at the BROADCAST multiple
      (see ManagedTrade.verdict/2, the nil clause)

  ## HISTORY NOTE — the nil contract changed, deliberately

  This module's original contract read "nil on any failure — an
  unverifiable absorption check SKIPS the trade rather than
  guessing." That policy was superseded when the verdict became a
  SIZING input instead of a skip decision (HARD RULE 1: every signal
  trades, no skips). nil now means "trade at the broadcast multiple,"
  not "skip." The docstring here is updated; any older session note
  describing Oracle-nil as a skip is obsolete.

  ## Failure posture — total

  EVERY failure path returns nil: HTTP error, non-200 status,
  malformed body, empty kline list, unparseable price, even an
  unexpected crash (the rescue clause). The Oracle never raises into
  its caller — the caller is a GenServer's init path, and a raise
  there would crash-loop the trade process. A nil verdict is a known,
  handled outcome; a crash is not.

  ## Precision notes

    - startTime=<anchor_ms>&limit=1 fetches the bar OPENING at the
      anchor — Binance klines are open-time-keyed, so no offset
      arithmetic is needed and no off-by-one is possible.
    - Index 4 of a kline row is the CLOSE price (Binance's array
      layout: open_time, open, high, low, close, ...).
    - Prices arrive as strings ("80879.10") — Float.parse, never
      String.to_float (which would crash on scientific notation or
      malformed data instead of returning nil).
  """

  require Logger

  # Compile-time env read: the URL is fixed for the life of the node.
  # BINANCE_FAPI_URL exists so a test/CI environment can point the
  # Oracle at a stub; production uses the default fapi host.
  @fapi System.get_env("BINANCE_FAPI_URL", "https://fapi.binance.com")

  # Single-symbol deployment: the executor trades BTC ladders only.
  # If the wire format ever carries other symbols, this must become
  # a parameter of close_at_bar/2 — the ManagedTrade call site holds
  # the ladder and can pass it.
  @symbol "BTCUSDT"

  @doc """
  The closing price of the 1m bar that OPENED at `ts`, or nil on any
  failure.

  Called at most once per trade (late registration only) — there is
  no caching because the request pattern is one-shot by design. The
  1m kline for a closed bar is immutable on the exchange, so a
  repeated call would return the same value; the cost is one HTTP
  round-trip per late trade, which is negligible at this feed's
  volume.
  """
  @spec close_at_bar(DateTime.t()) :: float() | nil
  def close_at_bar(ts) do
    ms = DateTime.to_unix(ts, :millisecond)
    url = @fapi <> "/fapi/v1/klines?symbol=#{@symbol}&interval=1m&startTime=#{ms}&limit=1"

    case Finch.build(:get, url) |> Finch.request(RiptideExecutor.Finch) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode!(body) do
          # Jason decodes JSON arrays as LISTS (not tuples), so index
          # access is Enum.at — Access-style bracket syntax would
          # raise Protocol.UndefinedError on a list.
          [row | _] when is_list(row) ->
            case Enum.at(row, 4) do
              nil ->
                nil

              close_str ->
                case Float.parse(close_str) do
                  {f, _} -> f
                  :error -> nil
                end
            end

          # Empty kline list: the bar doesn't exist yet (future anchor
          # or exchange gap). nil — the caller trades at the broadcast
          # multiple.
          _ ->
            nil
        end

      # Non-200 (rate limit, IP ban, exchange 5xx): logged with the
      # body for forensics, nil for the caller.
      {:ok, %{status: status, body: body}} ->
        Logger.warning("Oracle: kline fetch #{status}: #{inspect(body)}")
        nil

      {:error, reason} ->
        Logger.warning("Oracle: fetch failed: #{inspect(reason)}")
        nil
    end
  rescue
    # The catch-all: ANY unexpected raise in this function (a weird
    # body shape, a Jason quirk, a DateTime edge) degrades to nil.
    # The verdict path handles nil; it must never handle a raise.
    e ->
      Logger.error("Oracle: crashed: #{inspect(e)}")
      nil
  end
end

