defmodule RiptideExecutor.MarketFeed do
  @moduledoc """
  The per-minute oracle: aligned to exchange bar closes, fetches the
  just-closed 1-minute kline from Binance Futures and broadcasts
  `{:pulse, bar_ts, close_price}` to every subscribed ManagedTrade.

  Bar counting AND decision pricing advance on THIS data — the
  exchange's closed bar. A failed fetch still dispatches the pulse
  with a nil price (trades hold their last price and keep counting
  bars — a data hole must not freeze the bar count).

  Health: status/0 exposes feed liveness — last successful fetch,
  consecutive failures, last price. Consumed by RiptideExecutor.Status
  so the console view shows oracle health alongside trade state.
  """

  use GenServer

  require Logger

  @fapi_url System.get_env("BINANCE_FAPI_URL", "https://fapi.binance.com")
  @symbol "BTCUSDT"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # === Health ===

  @doc "Feed liveness: last success, consecutive failures, last price."
  def status do
    st =
      :persistent_term.get({__MODULE__, :status}, %{last_ok: nil, failures: 0, last_price: nil})

    Map.put(st, :alive?, st.failures < 3 and st.last_ok != nil)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    # The bar that just closed is the one ending at this instant.
    sec = System.system_time(:second)
    bar_ts = DateTime.from_unix!(sec - rem(sec, 60), :second)
    price = fetch_closed_price()

    Registry.dispatch(RiptideExecutor.PulseRegistry, :minute, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:pulse, bar_ts, price})
    end)

    record(price)

    Logger.info(
      "MarketFeed: #{DateTime.to_iso8601(bar_ts)} close " <>
        if(price, do: "$#{Float.round(price, 2)}", else: "UNAVAILABLE")
    )

    schedule_tick()
    {:noreply, state}
  end

  # === Health bookkeeping ===

  defp record(price) do
    prev = :persistent_term.get({__MODULE__, :status}, %{})

    st =
      if price do
        %{last_ok: DateTime.utc_now(), failures: 0, last_price: price}
      else
        %{
          last_ok: prev[:last_ok],
          failures: (prev[:failures] || 0) + 1,
          last_price: prev[:last_price]
        }
      end

    :persistent_term.put({__MODULE__, :status}, st)
  end

  # The last CLOSED 1m bar: the API's last element is the bar in
  # progress, so take the second-to-last. Enum.at — Jason decodes
  # arrays as lists and lists don't support index Access.
  defp fetch_closed_price do
    url = @fapi_url <> "/fapi/v1/klines?symbol=#{@symbol}&interval=1m&limit=2"

    case Finch.build(:get, url) |> Finch.request(RiptideExecutor.Finch) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode!(body) do
          [_, closed | _] when is_list(closed) ->
            case Enum.at(closed, 4) do
              nil ->
                nil

              close_str ->
                case Float.parse(close_str) do
                  {f, _} -> f
                  :error -> nil
                end
            end

          _ ->
            nil
        end

      {:ok, %{status: status, body: body}} ->
        Logger.warning("MarketFeed: kline fetch #{status}: #{inspect(body)}")
        nil

      {:error, reason} ->
        Logger.warning("MarketFeed: kline fetch failed: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.error("MarketFeed: kline fetch crashed: #{inspect(e)}")
      nil
  end

  # Aligned to the next minute boundary, exactly.
  defp schedule_tick do
    now_ms = System.system_time(:millisecond)
    ms_to_next_minute = 60_000 - rem(now_ms, 60_000)
    Process.send_after(self(), :tick, ms_to_next_minute)
  end
end

