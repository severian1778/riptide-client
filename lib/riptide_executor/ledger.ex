defmodule RiptideExecutor.Ledger do
  @moduledoc """
  DETS-backed journal of every trade decision, fill, and state-machine
  event. Survives restarts.

  ## Role — the fund's memory

  The Ledger is the executor's ONLY durable state. Everything the
  restart story depends on lives here: what was already traded
  (dedupe), what is open (Reconcile/Status), what fills actually
  happened (the never-stack guard reads fills, and TrackRecord
  reports from closed trades), and the exact event sequence of every
  walk (the forensic record used to diagnose incidents like the
  2026-10-28 nonce crash — `event_log/1` is what you read first
  after any anomaly). If it isn't in the Ledger, it didn't happen.

  ## The four tables

    - :exec_trades   — one record per accepted trade (key: the dedupe
                       triple {symbol, market_type, anchor_ts}).
                       Status: :open | :closed. Closed records carry
                       total_r, ending, closed_at, and the reporting
                       fields (absorbed, multiples, kelly_eff,
                       capital_risked) that TrackRecord sums.
    - :exec_fills    — every exchange fill, tagged with the leg it
                       belongs to (:entry, {:bank, tier}, :stop,
                       :stop_exit). Storage key: {key, i, leg} where
                       i is the monotonic journal counter.
    - :exec_events   — the state-machine journal. Event names mirror
                       LadderRunner's log types: :bank,
                       :timeout_escalate, :stop, :timeout_stop,
                       :final_expiry — plus the executor-side
                       terminals (:entry_failed, :deadzone_skip,
                       :stop_lost, :flatten_failed) and the
                       bookkeeping endings written by TradeEngine
                       (:dry_run) and Reconcile (:orphan).
    - :exec_seen     — the Dedupe table, DETS-backed so restart
                       reconciliation can distinguish "already
                       traded" from "never seen". Value: the
                       wall-clock ms at mark time (informational
                       only; membership is the semantics).

  ## Concurrency model — single writer, many readers

  ALL writes go through this GenServer (GenServer.call), which
  serializes them: two processes can never interleave a
  record_fill with a close_trade into a torn state. READS are
  direct :dets lookups from any process, bypassing the GenServer
  entirely — cheap, lock-free, and safe because DETS reads of a
  :set table don't conflict with inserts in any way that matters
  for this workload (last-writer-wins per key, and the walk's
  read-check-then-write pattern tolerates that). The one caveat:
  a read may see the state from just before an in-flight write —
  acceptable everywhere it's used (status views, guards that fail
  safe).

  ## Why DETS (and not ETS/Postgres/SQLite)

  DETS is the BEAM's built-in disk-based term storage — same API
  shape as ETS, backed by a file, no schema, no external service^5^.
  The requirements here are modest: a few thousand records, single
  node, survive restarts, zero dependencies. DETS is exactly that
  niche. The known trade-offs are accepted knowingly: single-file
  2GB ceiling (years of trades at this volume), and sync cost on
  every write (below). A multi-venue or multi-node future wants a
  real DB (see the Elixir ecosystem's double-entry ledgers for that
  evolution path^4,7^) — not this deployment.

  ## JOURNAL ORDERING (hard rule)

  Storage keys for fills and events carry
  System.unique_integer([:positive, :monotonic]) — each call
  returns a strictly larger number than the last PROCESS-WIDE, so
  fills/1 and event_log/1's sort_by is chronological BY
  CONSTRUCTION, not by luck. The audit trail must never depend on
  an ordering accident: without the :monotonic flag,
  unique_integer guarantees only uniqueness, and sequential events
  can sort out of order (observed live: :timeout_stop sorting
  before the :timeout_escalate that caused it — a false journal
  that would send any future incident investigation the wrong way).
  Monotonic integers are handed out under the GenServer's own
  serialization, so the guarantee has no race window.

  ## Durability — auto_save plus explicit sync

  Tables are opened with repair: true (a dirty shutdown self-heals
  on next open) and auto_save: 10_000 (a checkpoint every 10s).
  On top of that, every WRITE path calls maybe_sync/1 — an explicit
  :dets.sync flushes to disk immediately. The crash math this
  buys: at most one write is ever at risk (the one in flight),
  because the previous write was already synced. A ledger that can
  lose the record of an entry fill would defeat the never-stack
  guard on restart — sync-on-write is what makes that impossible.

  Directory via LEDGER_DIR (default priv/ledger). Tests pass
  dir: explicitly to isolate from production files.
  """

  use GenServer
  require Logger

  # The four table names — single source of truth for open_table,
  # the test-suite wipe helper, and any future inspection tooling.
  @tables [:exec_trades, :exec_fills, :exec_events, :exec_seen]

  # Named process — exactly one per node; callers address it by
  # name and never hold a pid.
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Directory resolution order: explicit opts (tests) → LEDGER_DIR
    # env → priv/ledger default. mkdir_p! rather than mkdir: a
    # missing parent chain must be created, not crashed on.
    dir = Keyword.get(opts, :dir) || System.get_env("LEDGER_DIR") || "priv/ledger"
    File.mkdir_p!(dir)
    Enum.each(@tables, &open_table(&1, dir))
    {:ok, %{dir: dir}}
  end

  # repair: true — a killed node (SIGKILL, power loss) leaves DETS
  # needing repair; auto-repair on open means a restart never needs
  # manual intervention. auto_save: 10_000 — periodic checkpoint
  # under the explicit sync (belt and braces, per the moduledoc).
  defp open_table(table, dir) do
    path = Path.join(dir, "#{table}.dets")

    {:ok, _} =
      :dets.open_file(table,
        file: to_charlist(path),
        repair: true,
        auto_save: 10_000
      )
  end

  # === Writes (single-writer) ===
  # Every public write is a GenServer.call — synchronous, so the
  # caller (a walk mid-state-transition) knows its journal entry is
  # IN before it proceeds to the next venue call. Call, not cast:
  # fire-and-forget journaling would let a crash race the write.

  @doc "Opens a trade record under the dedupe key, status :open, opened_at stamped here."
  def record_trade(key, payload) do
    GenServer.call(__MODULE__, {:record_trade, key, payload})
  end

  @doc """
  Journals an exchange fill under its walk-leg. `leg` is :entry,
  {:bank, tier}, :stop, or :stop_exit — the leg tag is what makes
  fills/1's output readable as a trade narrative rather than a
  blob.
  """
  def record_fill(key, leg, fill) do
    GenServer.call(__MODULE__, {:record_fill, key, leg, fill})
  end

  @doc "Journals a state-machine event (:bank, :timeout_escalate, :stop, ...)."
  def record_event(key, event, detail \\ %{}) do
    GenServer.call(__MODULE__, {:record_event, key, event, detail})
  end

  @doc "Merges the final map into the trade record and flips status to :closed."
  def close_trade(key, final) do
    GenServer.call(__MODULE__, {:close_trade, key, final})
  end

  @doc "Merges fields into an existing trade record (multiples, capital)."
  def update_trade(key, fields) do
    GenServer.call(__MODULE__, {:update_trade, key, fields})
  end

  @doc "Marks the dedupe triple as seen — the Feed calls this BEFORE deciding to trade."
  def mark_seen(key) do
    GenServer.call(__MODULE__, {:mark_seen, key})
  end

  # === Reads (direct, any process) ===
  # No GenServer hop: :dets reads are safe from any process and the
  # single-writer model guarantees no torn writes to read. All reads
  # tolerate absence (nil / []) rather than raising — callers treat
  # "not in the ledger" as a normal state, not an error.

  @doc "The trade record for a key, or nil if never recorded."
  def get_trade(key) do
    case :dets.lookup(:exec_trades, key) do
      [{^key, trade}] -> trade
      [] -> nil
    end
  end

  @doc "Keys of all :open trades — Status's trade list and Reconcile's work queue."
  def open_trades do
    :dets.match(:exec_trades, :"$1")
    |> Enum.map(&hd/1)
    |> Enum.filter(fn {_k, t} -> t.status == :open end)
    |> Enum.map(fn {k, _t} -> k end)
  end

  @doc "Keys of ALL trades ever recorded — TrackRecord's universe."
  def trade_keys do
    :dets.match(:exec_trades, :"$1")
    |> Enum.map(&hd/1)
    |> Enum.map(fn {k, _t} -> k end)
  end

  @doc "Event DETAILS only, unsorted (see event_log/1 for the ordered, named journal)."
  def events(key) do
    :dets.match(:exec_events, :"$1")
    |> Enum.map(&hd/1)
    |> Enum.filter(fn {{k, _i, _e}, _d} -> k == key end)
    |> Enum.map(fn {_k, d} -> d end)
  end

  @doc """
  This trade's fills in journal order: entry → banks → exit. The
  sort is over the monotonic integer in the storage key —
  chronological by construction (see moduledoc). The never-stack
  guard in ManagedTrade reads this: fills != [] means an entry
  exists and the trade must never re-open.
  """
  def fills(key) do
    :dets.match(:exec_fills, :"$1")
    |> Enum.map(&hd/1)
    |> Enum.filter(fn {{k, _i, _leg}, _f} -> k == key end)
    |> Enum.sort_by(fn {{_k, i, _leg}, _f} -> i end)
    |> Enum.map(fn {_storage_key, fill} -> fill end)
  end

  @doc """
  The journal WITH event names, in order: [{event, detail}].

  THE forensic view. After any incident, this is the first thing
  read: it replays the walk's decision sequence exactly as the
  state machine experienced it. Sort key is the monotonic counter,
  same as fills/1 — ordering is structural, never incidental.
  """
  def event_log(key) do
    :dets.match(:exec_events, :"$1")
    |> Enum.map(&hd/1)
    |> Enum.filter(fn {{k, _i, _e}, _d} -> k == key end)
    |> Enum.sort_by(fn {{_k, i, _e}, _d} -> i end)
    |> Enum.map(fn {storage_key, detail} -> {storage_leg(storage_key), detail} end)
  end

  # The event name rides the storage key's third element — pulled
  # back out after the sort so the journal can be name-tagged
  # without duplicating the name inside the detail map.
  defp storage_leg({_k, _i, leg}), do: leg

  @doc "Has this dedupe triple been marked seen? Membership only; the timestamp value is ignored."
  def seen?(key), do: :dets.lookup(:exec_seen, key) != []

  # === GenServer plumbing ===

  # opened_at is stamped HERE, in the writer, not by the caller —
  # one clock for all trade records, no caller-dependent skew.
  @impl true
  def handle_call({:record_trade, key, payload}, _from, state) do
    now = DateTime.utc_now()

    # Merge, not replace: the caller's payload (pred, source, kind)
    # is preserved and the ledger owns the lifecycle fields.
    :dets.insert(:exec_trades, {key, Map.merge(payload, %{status: :open, opened_at: now})})
    maybe_sync(:exec_trades)
    {:reply, :ok, state}
  end

  # The monotonic integer lives in the STORAGE KEY, not the fill
  # map — the fill map stays a pure data record of what the venue
  # did (price, qty), and ordering metadata never leaks into it.
  @impl true
  def handle_call({:record_fill, key, leg, fill}, _from, state) do
    :dets.insert(:exec_fills, {{key, System.unique_integer([:positive, :monotonic]), leg}, fill})
    maybe_sync(:exec_fills)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_event, key, event, detail}, _from, state) do
    :dets.insert(
      :exec_events,
      {{key, System.unique_integer([:positive, :monotonic]), event}, detail}
    )

    maybe_sync(:exec_events)
    {:reply, :ok, state}
  end

  # Read-modify-write is safe here BECAUSE of the single-writer
  # model: no other writer can interleave between the lookup and
  # the insert. This is exactly the race the GenServer serialization
  # exists to prevent.
  @impl true
  def handle_call({:update_trade, key, fields}, _from, state) do
    case :dets.lookup(:exec_trades, key) do
      [{^key, trade}] ->
        :dets.insert(:exec_trades, {key, Map.merge(trade, fields)})
        maybe_sync(:exec_trades)

      # Unknown key: log, don't raise. A write for a key that was
      # never recorded means an upstream identity mismatch — that's
      # a loud error in the logs, not a crash of the writer (the
      # writer being down would block ALL trades' journaling).
      [] ->
        Logger.error("Ledger: update_trade for unknown key #{inspect(key)}")
    end

    {:reply, :ok, state}
  end

  # Close = merge final fields + force status :closed. The status
  # put comes AFTER the merge so a caller-provided map can never
  # accidentally reopen or spoof the lifecycle field.
  @impl true
  def handle_call({:close_trade, key, final}, _from, state) do
    case :dets.lookup(:exec_trades, key) do
      [{^key, trade}] ->
        :dets.insert(:exec_trades, {key, Map.merge(trade, final) |> Map.put(:status, :closed)})
        maybe_sync(:exec_trades)

      [] ->
        Logger.error("Ledger: close_trade for unknown key #{inspect(key)}")
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_seen, key}, _from, state) do
    # Value is wall-clock ms at mark time — pure forensics
    # ("when did we first see this"), never read for logic.
    :dets.insert(:exec_seen, {key, System.system_time(:millisecond)})
    maybe_sync(:exec_seen)
    {:reply, :ok, state}
  end

  # Flush immediately after every write — the durability contract
  # in the moduledoc (at most one in-flight write at risk). The
  # size>0 guard skips sync on a theoretically-empty table (never
  # happens on a real write path, but costs nothing).
  defp maybe_sync(table) do
    if :dets.info(table, :size) > 0, do: :dets.sync(table)
  end
end

