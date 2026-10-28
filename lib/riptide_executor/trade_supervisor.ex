defmodule RiptideExecutor.TradeSupervisor do
  @moduledoc """
  DynamicSupervisor for ManagedTrade processes — one child per open
  ladder trade, registered by the dedupe key in TradeRegistry.

  ## Why a DynamicSupervisor

  Trades are not known at boot — they start when a ladder arrives on
  the feed and stop when the walk closes them. DynamicSupervisor is
  the OTP primitive for exactly that: a supervisor whose children are
  added and removed at runtime. One process per trade gives:

    - ISOLATION — a crash in one walk (a bad venue response, a
      placement raise) cannot touch any other open trade. The
      supervisor restarts or retires the crashed child alone.
    - LIFECYCLE = LEDGER LIFECYCLE — a trade process exists exactly
      as long as its ledger record is :open. Status.print uses this:
      an open ledger record with no process under this supervisor is
      a 💀 NOT RUNNING line, and Reconcile's ghost/orphan logic keys
      off the same fact.
    - BOUNDED RESTARTS — :one_for_one with :transient restarts means
      a crash restarts the walk at most once per clean exit class
      (see below), never a crash loop against a live position.

  ## The restart policy — :transient, and why it is load-bearing

  `restart: :transient` means: restart ONLY on abnormal exit, never
  on a normal `{:stop, :normal, _}`. ManagedTrade exits :normal in
  every legitimate terminal state (book_exit, entry_failed,
  deadzone_skip, the never-stack refusal) — those must NOT restart,
  or a closed trade would immediately re-open, hit the never-stack
  guard, and thrash. A CRASH (an unexpected exception, e.g. the
  duplicate-nonce MatchError of 2026-10-28) DOES restart the child —
  which is deliberate: the restarted walk re-reads the ledger, finds
  the entry fill already recorded, and refuses to re-open (HARD RULE
  6), leaving the ledger record open for Reconcile to flag rather
  than silently re-trading. The policy encodes the fund's invariant:
  a normal end is final; a crash hands over to a human, not to a
  retry.

  ## Dedupe via the child id

  The spec id is `{RiptideExecutor.ManagedTrade, key}` where key is
  the dedupe triple {symbol, market_type, anchor_ts}. DynamicSupervisor
  rejects a start_child whose id already exists, which surfaces as
  `{:error, {:already_started, pid}}` — TradeEngine treats that as a
  benign duplicate and logs a warning. This is the second layer of
  at-most-once execution (the first is the DETS-backed Dedupe set in
  the Feed; this one covers a same-session double-delivery racing
  between the two).

  Registration is doubled: the child id here guards supervisor-level
  uniqueness, while the :via Registry name inside ManagedTrade's own
  start_link guards process-level lookup (Status/Reconcile find a
  live walk by key without asking this supervisor).
  """

  use DynamicSupervisor

  # Named process — exactly one per executor tree, started by the
  # Application supervisor when RIPTIDE_API_TOKEN is set. start_trade/1
  # addresses it by name, so callers never hold a pid.
  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # :one_for_one — children are independent by construction (each walk
  # owns its own venue orders). No trade's failure should cascade to
  # another's restart, and no trade has a supervision relationship to
  # any other.
  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts one ManagedTrade under this supervisor.

  `args` is the tuple {venue_module, oracle_module, key, ladder,
  bankroll} — passed through untouched to ManagedTrade.start_link/1.
  Returns:

    - `{:ok, pid}`  — trade started, walk is live
    - `{:error, {:already_started, pid}}` — this key already has a
      walk (duplicate delivery or double start); benign, caller logs
      and moves on
    - `{:error, reason}` — genuine start failure (e.g. registry
      name taken by a dying-but-not-yet-dead predecessor)

  The child id embeds the dedupe key, making supervisor-level
  uniqueness itself the duplicate guard.
  """
  def start_trade(args) do
    spec = %{
      id: {RiptideExecutor.ManagedTrade, elem(args, 2)},
      start: {RiptideExecutor.ManagedTrade, :start_link, [args]},
      # :transient — restart on crash, never on a normal terminal
      # exit. See moduledoc: a normal exit is final; a crash restarts
      # into the never-stack guard, which leaves the record open for
      # a human instead of re-trading.
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end

