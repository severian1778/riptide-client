defmodule RiptideExecutor.Feed do
  @moduledoc """
  Phoenix channel client for the central Riptide prediction feed.

  ## Role in the system

  `Feed` is the ingestion edge of the executor. It maintains a single
  long-lived WebSocket connection to the central server, joins the
  prediction topic for the configured market, and forwards each
  incoming prediction to `RiptideExecutor.TradeEngine` — subject to
  deduplication via `RiptideExecutor.Dedupe`.

  ## Connection lifecycle

  The connection is established in `init/1` using Slipstream's
  `connect/1`, which returns the `%Slipstream.Socket{}` that serves as
  this process's entire state. Every callback must return
  `{:ok, socket}`; returning anything else raises on the first
  dispatched event.

  ### Reconnection

  Slipstream does **not** reconnect automatically. On disconnect,
  `handle_disconnect/2` schedules a `:reconnect` message and calls
  `connect/1` when it arrives. Reconnection is deliberately deferred
  rather than attempted inline: an immediately-failing server would
  otherwise produce a hot reconnect loop. The retry delay is a flat
  5 seconds — adequate for a single-executor topology, and simple
  enough to reason about under failure.

  ## Join backfill and the freshness window

  Phoenix channels replay recent messages on join. These backfilled
  predictions are marked seen **without trading** — with one
  exception: predictions whose anchor is younger than
  `@backfill_freshness_seconds` (2 minutes). Those are trades that
  fired while this executor was down, and executing them preserves
  the at-most-once-executed guarantee the system aims for.

  Live pushes follow the same path but skip the freshness check,
  since a live push is by definition current.

  ## Deduplication contract

  The feed is at-least-once: the inclusive cursor and the join
  backfill both re-deliver messages. Deduplication is therefore
  mandatory consumer behavior per the API spec, and is keyed on the
  `(symbol, market_type, anchor_ts)` triple — the natural idempotency
  key for a prediction.

  ## Authentication

  The bearer token (`RIPTIDE_API_TOKEN`) travels in the URI query
  string. Slipstream has no `:params` option; Phoenix reads connect
  params from the query string regardless of transport, so this is
  the canonical mechanism, not a workaround.
  """

  use Slipstream

  require Logger

  alias RiptideExecutor.Dedupe
  alias RiptideExecutor.TradeEngine

  @typep socket :: Slipstream.Socket.t()

  # Age (in seconds) below which a backfilled prediction is treated
  # as "fired while we were down" and executed rather than skipped.
  @backfill_freshness_seconds 120

  # Delay (in milliseconds) before attempting reconnection after a
  # disconnect. Deferred to avoid a hot loop against a dead server.
  @reconnect_delay_ms 5_000

  @doc """
  Starts the Feed process linked to the supervisor.

  There are no runtime options; all configuration is sourced from the
  environment (`RIPTIDE_API_TOKEN`, `RIPTIDE_WS_URL`, `MARKET`).

  ## Examples

      RiptideExecutor.Feed.start_link([])

  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts), do: Slipstream.start_link(__MODULE__, :ok, name: __MODULE__)

  ## ==========================================================================
  ## Callbacks: lifecycle
  ## ==========================================================================

  @impl Slipstream
  @doc """
  Initializes the socket state.

  Reads `RIPTIDE_API_TOKEN` (required — the application supervisor
  only starts this child when the token is present) and
  `RIPTIDE_WS_URL` (defaulting to the local development server), then
  initiates the WebSocket connection. The returned socket becomes the
  process state; all subsequent callbacks receive and return it.
  """
  @spec init(:ok) :: {:ok, socket()}
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
  @doc """
  Handles a successful transport connection.

  Joins the prediction topic for the configured market
  (`MARKET`, default `"futures"`). No trading occurs until the join
  reply arrives.
  """
  @spec handle_connect(socket()) :: {:ok, socket()}
  def handle_connect(socket) do
    market = System.get_env("MARKET", "futures")
    Logger.info("Feed: connected to central server")
    {:ok, join(socket, "predictions:" <> market, %{})}
  end

  @impl Slipstream
  @doc """
  Handles a successful topic join.

  Any backfill delivered as part of the join arrives as ordinary
  `handle_message/4` events *after* this callback, where the
  freshness window in `fresh_backfill?/1` decides execution.
  """
  @spec handle_join(String.t(), map(), socket()) :: {:ok, socket()}
  def handle_join(topic, _join_reply, socket) do
    Logger.info("Feed: joined #{topic} — live, waiting for trades")
    {:ok, socket}
  end

  ## ==========================================================================
  ## Callbacks: message handling
  ## ==========================================================================

  @impl Slipstream
  @doc """
  Handles a prediction push on the predictions topic.

  Routing logic, in strict order:

    1. **Already seen** — drop silently. At-least-once delivery means
       duplicates are expected, not exceptional.
    2. **Fresh backfill** — the prediction's anchor is within
       `@backfill_freshness_seconds` of now, meaning it fired while
       this executor was down. Mark seen, then execute.
    3. **Stale backfill** — mark seen, do not execute. The join
       backfill replays history we deliberately did not trade.
    4. **Live push** — falls into the same branch as stale backfill;
       a live push arrives immediately after being marked, and the
       freshness check's `age >= 0` guard covers clock skew.

  Every branch terminates in `{:ok, socket}` — a crash here would
  take down the sole ingestion path.
  """
  @spec handle_message(String.t(), String.t(), map(), socket()) :: {:ok, socket()}
  def handle_message(
        "predictions:" <> _market,
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

  @spec handle_message(String.t(), String.t(), map(), socket()) :: {:ok, socket()}
  def handle_message(topic, event, payload, socket) do
    Logger.debug("Feed: unhandled #{topic} #{event} #{inspect(payload)}")
    {:ok, socket}
  end

  ## ==========================================================================
  ## Callbacks: failure and recovery
  ## ==========================================================================

  @impl Slipstream
  @doc """
  Handles a transport disconnect or failed connection attempt.

  Slipstream dispatches two shapes here: `{:error, reason}` when a
  connect attempt fails (this includes the very first one from
  `init/1`), and `%{reason: reason}` when an established connection
  closes. Both must be handled or the process crashes instead of
  retrying.

  Slipstream does not reconnect on its own; this handler schedules the
  retry. `:econnrefused` means nothing is listening at the target
  host:port; `:timeout` means the path is blocked; a map with a
  `:status` key means the server rejected the WebSocket upgrade.
  """
  @spec handle_disconnect({:error, term()} | map(), socket()) :: {:ok, socket()}
  def handle_disconnect({:error, reason}, socket) do
    Logger.warning("Feed: connect failed (#{inspect(reason)}) — retrying in 5s")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:ok, socket}
  end

  def handle_disconnect(%{reason: reason}, socket) do
    Logger.warning("Feed: disconnected (#{inspect(reason)}) — retrying in 5s")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:ok, socket}
  end

  @impl true
  @doc """
  Handles the deferred `:reconnect` message.

  Uses `Slipstream.reconnect/1`, which re-establishes the connection
  from the socket's stored configuration. `connect/1` would be wrong
  here — it expects a fresh config keyword list, not a socket.
  """
  @spec handle_info(:reconnect, socket()) :: {:noreply, socket()}
  def handle_info(:reconnect, socket) do
    case reconnect(socket) do
      {:ok, socket} -> {:noreply, socket}
      # a failed reconnect surfaces as handle_disconnect/2 — keep the loop alive
      _ -> {:noreply, socket}
    end
  end

  ## ==========================================================================
  ## Private helpers
  ## ==========================================================================

  # Determines whether a prediction arrived via join backfill but is
  # still fresh enough to act on — i.e. it fired within
  # @backfill_freshness_seconds of now, meaning the executor was down
  # when it went out. A negative age indicates a future-dated or
  # malformed anchor and is treated as not fresh.
  #
  # Unparseable anchors are never traded: an execution decision must
  # never rest on data we cannot validate.
  @spec fresh_backfill?(map()) :: boolean()
  defp fresh_backfill?(pred) do
    case DateTime.from_iso8601(pred["anchor_ts"]) do
      {:ok, ts, _offset} ->
        age = DateTime.diff(DateTime.utc_now(), ts, :second)
        age >= 0 and age <= @backfill_freshness_seconds

      _ ->
        false
    end
  end
end
