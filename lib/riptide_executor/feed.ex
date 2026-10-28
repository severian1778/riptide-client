defmodule RiptideExecutor.Feed do
  @moduledoc """
  Phoenix channel client for the central Riptide prediction feed.

  Connects to the central server, joins the prediction topic for the
  configured market, and routes incoming trades to the TradeEngine.
  This is the executor's FRONT DOOR: the only component that talks
  to the central server, and the first of the two at-most-once
  execution gates (the second is TradeSupervisor's child id).

  LADDERS ONLY: the only tradeable event is "ladder_prediction" — the
  full multi-tier ladder trade. The legacy flat "prediction" event is
  received and deliberately ignored, never traded.

  ## Connection lifecycle

  The connection is established in `init/1` using Slipstream's
  `connect/1`. Slipstream does not reconnect automatically; on
  disconnect, `handle_disconnect/2` schedules a `:reconnect` message
  (flat 5s delay — deferred rather than inline to avoid a hot loop
  against a dead server). A failed reconnect attempt re-enters
  handle_disconnect/2, so the retry loop is self-sustaining until
  the server returns — the Feed never gives up, and never crashes
  trying.

  ## Join backfill and the freshness window

  The channel join replays recent predictions. Backfilled ladders are
  marked seen WITHOUT trading — except ladders whose anchor is younger
  than @backfill_freshness_seconds (2 minutes): those fired while this
  executor was down, and executing them preserves the
  at-most-once-executed guarantee (skip them and a signal that
  deserves a trade is lost; trade them all and a restart replays
  history).

  ## Deduplication contract

  The feed is at-least-once: the inclusive cursor and the join
  backfill both re-deliver. Dedupe is keyed on the
  (symbol, market_type, anchor_ts) triple and is DETS-backed via the
  Ledger, so restarts don't forget what was already traded. Marking
  happens BEFORE TradeEngine.execute/1 in the trade path — if the
  process dies between mark and execute, the trade is lost but never
  duplicated; the reverse ordering would trade twice on a crash
  between the two. Loss-of-one-signal beats double-execution.

  ## Authentication

  The bearer token (`RIPTIDE_API_TOKEN`) travels in the URI query
  string — Slipstream has no `:params` option, and Phoenix reads
  connect params from the query regardless of transport.

  ## Semantics note — "fresh_backfill?" is really "fresh enough to
  trade"

  Despite the name, fresh_backfill?/1 gates EVERY non-duplicate
  ladder, live push included. This is correct in practice: a live
  push arrives seconds after its anchor, so it always passes the
  120s window; only genuinely stale input (backfill replay of old
  history) fails it. The name is kept because renaming it would
  churn the diff for zero behavior change — but a reader should
  understand the routing as: seen? → drop; fresh? → trade;
  stale → mark-and-ignore.
  """

  use Slipstream

  require Logger

  alias RiptideExecutor.{Dedupe, Ledger, TradeEngine}

  @typep socket :: Slipstream.Socket.t()

  # Age (seconds) below which a backfilled ladder is treated as
  # "fired while we were down" and executed rather than skipped.
  # 120s = two full anchor+entry cycles: enough to cover a short
  # restart, short enough that a late entry is still inside the
  # trade's meaningful life (the walk's own queue tolerates the
  # anchor being closed — the Oracle handles the verdict).
  @backfill_freshness_seconds 120

  # Delay (ms) before reconnecting after a disconnect. Flat (not
  # exponential backoff): the server is either up or it isn't, and
  # a 5s probe is cheap. Inline retries would hot-loop against a
  # dead server and burn the process mailbox.
  @reconnect_delay_ms 5_000

  @doc """
  Starts the Feed process linked to the supervisor.

  All configuration is sourced from the environment
  (`RIPTIDE_API_TOKEN`, `RIPTIDE_WS_URL`, `MARKET`). RIPTIDE_API_TOKEN
  is fetch_env! — a MISSING token raises at init, which is how the
  Application tree decides to start nothing at all (see
  Application.start/2: no token → no children). The Feed crashing on
  a missing token in isolation is fine; in the real tree it is
  simply never started.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts), do: Slipstream.start_link(__MODULE__, :ok, name: __MODULE__)

  ## ==========================================================================
  ## Callbacks: lifecycle
  ## ==========================================================================

  # The token goes in the URI query (see moduledoc — Slipstream has
  # no :params option). vsn=2.0.0 is the Phoenix websocket protocol
  # version query param the server's transport expects.
  @impl Slipstream
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

  # The topic is parameterized by MARKET so one executor binary can
  # serve futures or spot ladders by configuration alone. The join
  # triggers the server-side backfill replay — which arrives as
  # ordinary ladder_prediction messages and is handled by the same
  # routing logic as live pushes (that is the point).
  @impl Slipstream
  @spec handle_connect(socket()) :: {:ok, socket()}
  def handle_connect(socket) do
    market = System.get_env("MARKET", "futures")

    Logger.info("Feed: connected to central server")

    # join/2 RETURNS the socket — it does not return {:ok, socket}.
    # The original single-join code was {:ok, join(socket, ...)} for
    # exactly this reason. Chain both joins through the socket and
    # return {:ok, socket} once, at the end.
    socket = join(socket, "predictions:" <> market, %{})
    socket = join(socket, "predictions:spot", %{})

    {:ok, socket}
  end

  # Join confirmation only — the backfill has ALREADY started
  # arriving by the time this fires (Phoenix delivers replayed
  # messages as part of the join flow), so no action is needed
  # here. Logging "live" at join is the operator's heartbeat that
  # the front door is open.
  @impl Slipstream
  @spec handle_join(String.t(), map(), socket()) :: {:ok, socket()}
  def handle_join(topic, _join_reply, socket) do
    Logger.info("Feed: joined #{topic} — live, waiting for ladders")
    {:ok, socket}
  end

  ## ==========================================================================
  ## Callbacks: message handling — LADDERS ONLY
  ## ==========================================================================

  @impl Slipstream
  @doc """
  The tradeable event: a full ladder_prediction. Routing, in order:

    1. Already seen — drop. At-least-once delivery makes duplicates
       expected, not exceptional.
    2. Fresh (anchor within the 120s window) — fired while we were
       down, or a live push. Mark seen, record, execute.
    3. Stale — mark seen, do not trade (it's old history).

  The key is built from the raw wire strings (no parsing) so every
  downstream consumer — Dedupe, Ledger, TradeEngine, the walk's
  registry name — keys on the IDENTICAL value. elem/1 access
  instead of pattern-matching keeps the triple opaque.
  """
  @spec handle_message(String.t(), String.t(), map(), socket()) :: {:ok, socket()}
  def handle_message("predictions:" <> _market, "ladder_prediction", ladder, socket) do
    key = {ladder["symbol"], ladder["market_type"], ladder["anchor_ts"]}

    cond do
      # 1. Duplicate — the common case on reconnect (cursor replay).
      # Debug-level: normal operation, not an anomaly.
      Dedupe.seen?(elem(key, 0), elem(key, 1), elem(key, 2)) ->
        Logger.debug("Feed: duplicate ladder #{ladder["anchor_ts"]}, ignoring")

      # 2. Tradeable: fresh live push OR fresh backfill. Mark FIRST
      # (crash between mark and execute loses one signal; the other
      # order would double-trade — see moduledoc), then record the
      # ledger trade, then hand off. TradeEngine decides DRY_RUN
      # and venue; the Feed only routes.
      fresh_backfill?(ladder) ->
        Logger.info("Feed: LADDER trade @ #{ladder["anchor_ts"]}")
        Dedupe.mark(elem(key, 0), elem(key, 1), elem(key, 2))
        Ledger.record_trade(key, %{pred: ladder, source: :backfill, kind: :ladder})
        TradeEngine.execute(ladder)

      # 3. Stale backfill — history replay. Marked so it is never
      # re-considered, never traded. Silent beyond the mark: this
      # is the normal shape of a join replay's tail.
      true ->
        Dedupe.mark(elem(key, 0), elem(key, 1), elem(key, 2))
    end

    {:ok, socket}
  end

  # Legacy flat predictions are NOT traded — ladders only. The
  # clause exists so the event is explicitly recognized and logged
  # rather than falling into the generic unhandled bucket: a flat
  # prediction arriving is EXPECTED (the server still emits them),
  # and its presence in logs at debug confirms the contract is
  # holding.
  @impl Slipstream
  def handle_message("predictions:" <> _market, "prediction", _pred, socket) do
    Logger.debug("Feed: ignoring legacy flat prediction — ladders only")
    {:ok, socket}
  end

  # Catch-all: phoenix "phx_reply"/heartbeat frames, phx_error,
  # future event types. Debug-level and inert — the routing table
  # above is exhaustive for tradeable events, so anything landing
  # here is protocol traffic or a future feature the executor
  # hasn't been taught.
  @impl Slipstream
  def handle_message(topic, event, payload, socket) do
    Logger.debug("Feed: unhandled #{topic} #{event} #{inspect(payload)}")
    {:ok, socket}
  end

  ## ==========================================================================
  ## Callbacks: failure and recovery
  ## ==========================================================================

  # Three disconnect shapes, one policy: log, schedule a deferred
  # retry, return the socket unchanged (Slipstream keeps the config
  # stored on the socket for reconnect/1 to reuse). Open trades are
  # UNAFFECTED by a feed outage — walks run on MarketFeed pulses,
  # not on the prediction channel. Only NEW signals are lost during
  # the gap, and the join backfill recovers the fresh ones on
  # reconnect (that is what the freshness window is for).
  @impl Slipstream
  @doc """
  Handles a failed connect attempt or a closed connection. Slipstream
  dispatches `{:error, reason}` on connect failure and
  `%{reason: reason}` on close. Both schedule the deferred retry.
  """
  @spec handle_disconnect({:error, term()} | map(), socket()) :: {:ok, socket()}
  def handle_disconnect({:error, reason}, socket) do
    Logger.warning("Feed: connect failed (#{inspect(reason)}) — retrying in 5s")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:ok, socket}
  end

  def handle_disconnect(:closed, socket) do
    Logger.warning("Feed: channel closed — retrying in 5s")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:ok, socket}
  end

  def handle_disconnect(%{reason: reason}, socket) do
    Logger.warning("Feed: disconnected (#{inspect(reason)}) — retrying in 5s")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:ok, socket}
  end

  # The deferred retry. reconnect/1 re-establishes from the socket's
  # STORED config — calling connect/1 with a fresh config here would
  # discard the socket's session state and is the classic Slipstream
  # mistake. A failed reconnect re-enters handle_disconnect/2 (which
  # schedules the next attempt), so the loop is closed. The bare
  # `_` catch-all on the return covers Slipstream's non-{:ok, _}
  # return shapes without crashing the retry machinery itself.
  @impl Slipstream
  @doc """
  Handles the deferred `:reconnect` message via Slipstream.reconnect/1
  (re-establishes from the socket's stored config — connect/1 would be
  wrong here). A failed reconnect surfaces as handle_disconnect/2.
  """
  @spec handle_info(:reconnect, socket()) :: {:noreply, socket()}
  def handle_info(:reconnect, socket) do
    case reconnect(socket) do
      {:ok, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  ## ==========================================================================
  ## Private helpers
  ## ==========================================================================

  # True when the ladder's anchor is within @backfill_freshness_seconds
  # of now — i.e. it fired while this executor was down (or, for a
  # live push, simply just fired — see the moduledoc's semantics
  # note). A negative age (future-dated anchor) is never fresh:
  # clock skew must not cause execution of a signal that hasn't
  # happened yet. Unparseable anchors are never traded: an execution
  # decision must never rest on data we cannot validate — a
  # malformed anchor drops through to mark-and-ignore, which is the
  # safe terminal for garbage.
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
