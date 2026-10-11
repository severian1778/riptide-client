defmodule RiptideExecutor.Feed do
  @moduledoc """
  Phoenix channel client for the central prediction feed.

  Slipstream callback contract: every callback takes the
  %Slipstream.Socket{} and returns {:ok, socket}. The socket returned
  by connect/2 IS the process state — returning anything else crashes
  on the first event. The token travels in the URI query string
  (Slipstream has no :params option; Phoenix reads connect params
  from the query regardless).

  - Connects with the bearer token from RIPTIDE_API_TOKEN
  - Joins predictions:<MARKET> (MARKET from .env, default futures)
  - The join backfill is marked seen WITHOUT trading, except entries
    younger than 2 minutes — those are trades that fired while this
    executor was down
  - Live pushes are deduped then handed to TradeEngine
  """

  use Slipstream

  require Logger

  alias RiptideExecutor.{Dedupe, TradeEngine}

  def start_link(_opts), do: Slipstream.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl Slipstream
  def init(:ok) do
    token = System.fetch_env!("RIPTIDE_API_TOKEN")
    base = System.get_env("RIPTIDE_WS_URL", "ws://localhost:4003")

    config = [
      uri: URI.parse(base <> "/executor/websocket?token=#{URI.encode_www_form(token)}&vsn=2.0.0")
    ]

    {:ok, socket} = connect(config)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    market = System.get_env("MARKET", "futures")
    Logger.info("Feed: connected to central server")
    {:ok, join(socket, "predictions:" <> market, %{})}
  end

  @impl Slipstream
  def handle_join(topic, _join_reply, socket) do
    Logger.info("Feed: joined #{topic} — live, waiting for trades")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(
        "predictions:" <> _m,
        "prediction",
        %{"anchor_ts" => ts} = pred,
        socket
      ) do
    key = {pred["symbol"], pred["market_type"], ts}

    cond do
      Dedupe.seen?(elem(key, 0), elem(key, 1), elem(key, 2)) ->
        Logger.debug("Feed: duplicate #{ts}, ignoring")

      fresh_backfill?(pred) ->
        Logger.info("Feed: fresh backfill prediction (fired while we were down) — trading")
        Dedupe.mark(elem(key, 0), elem(key, 1), elem(key, 2))
        TradeEngine.execute(pred)

      true ->
        Dedupe.mark(elem(key, 0), elem(key, 1), elem(key, 2))
    end

    {:ok, socket}
  end

  def handle_message(topic, event, payload, socket) do
    Logger.debug("Feed: unhandled #{topic} #{event} #{inspect(payload)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_why, socket) do
    Logger.warning("Feed: disconnected — slipstream will reconnect automatically")
    {:ok, socket}
  end

  defp fresh_backfill?(pred) do
    case DateTime.from_iso8601(pred["anchor_ts"]) do
      {:ok, ts, _offset} ->
        age = DateTime.diff(DateTime.utc_now(), ts, :second)
        age >= 0 and age <= 120

      _ ->
        false
    end
  end
end

