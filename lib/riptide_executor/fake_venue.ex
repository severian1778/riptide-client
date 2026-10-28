defmodule RiptideExecutor.FakeVenue do
  @moduledoc """
  Deterministic test venue: fills orders against a price the test
  sets. No network, no timing — fills are computed from the current
  price on every order_status/1 poll, so tests drive the walk by
  sending {:pulse, ts, price} and :poll directly to the ManagedTrade
  and asserting on the Ledger.

  ## The design philosophy

  A fake venue earns its keep by getting exactly three things right,
  and they are the three things a hosted sandbox cannot do:
  conditionals, real prices, and deterministic, price-driven
  replay^1^. This module implements the minimal version of that
  idea for the ladder walk: the test sets ONE number (the price)
  and the venue's entire behavior is a pure function of that number
  plus the resting orders. No randomness, no wall-clock, no network
  — a test that fails today fails identically tomorrow, which is
  the whole point of a deterministic double.

  ## How tests drive the walk

  The control loop is explicit and synchronous:

      FakeVenue.set_price(102.5)   # the market's "truth"
      send(pid, {:pulse, ts, 102.5})  # MarketFeed's heartbeat, faked
      send(pid, :poll)             # the walk's venue check, forced

  The venue's fills are recomputed ON EVERY POLL from the current
  price — nothing is pushed, nothing is evented. This mirrors the
  real walk's actual information channel (order_status polling,
  per the Venue contract) rather than an idealized push model the
  production adapters don't have. Tests that pass here test the
  real detection path.

  ## Crossing rules — identical to a canonical exchange book

  - sell LIMIT fills when price >= level (a buyer lifted the ask)
  - buy  LIMIT fills when price <= level (a seller hit the bid)
  - sell STOP  triggers when price <= level (support broke)
  - buy  STOP  triggers when price >= level (resistance broke)
  - MARKET orders fill instantly at the CURRENT price, captured at
    placement time

  The fill price for a crossed limit/stop is the ORDER's level, not
  the market price — same convention as a resting maker on a real
  book, and the same convention the Hyperliquid adapter relies on
  (a resting limit fills AT its price). A market order's fill price
  is the price at placement, which is the right fidelity for an
  IoC-style market: it executed the moment it was sent.

  ## Known fidelity gaps — accepted, and WHY they're accepted

  - NO partial fills. An order is filled or untouched. This matches
    the walk's own design decision (tier advancement on FULL fill
    only) — modeling partials here would test a code path the walk
    refuses to use. If the walk ever learns partial-fill banking,
    this venue must grow it the same day, or the tests would lie.
  - NO intrabar path. The walk is polled on a single price per
    step; which resting order fills is decided by that price
    alone. A real bar's PATH (open→high→low→close) can fill a stop
    AND a limit in the same minute where a single close price
    cannot express both^6^ — the pinned walk tests sidestep this by
    never setting a price that crosses two orders at once. Tests
    that violate that discipline will diverge from live behavior;
    keep each step's price unambiguous.
  - `order_filled?/1` bare-matches `{:ok, ...}` — safe HERE because
    order_status/1 of this module can never return an error (ETS
    lookup always succeeds), unlike the real adapters. Do not copy
    this pattern into production adapters.

  ## Concurrency shape — an honest oddity

  The behaviour is a GenServer, but the GenServer does NOTHING
  except own the named ETS table's lifecycle (a named public table
  needs an owner to survive). Every operation — place, cancel,
  set_price, order_status — is a DIRECT :ets call from the calling
  process, completely bypassing the server. This is deliberate:
  tests must be able to set the price and read statuses without a
  message round-trip through a server that could serialize or
  reorder them, and ETS's own atomicity is sufficient for the
  single-test-process access pattern. Multi-threaded mutation of
  fake-venue state without a lock is a known hazard class in
  test doubles generally^2^ — here it is safe because the
  discipline is one driving process per test (async: false in the
  ManagedTrade suite for exactly this reason).

  ## The `[]` (cancelled/unknown) case matters

  order_status on a CANCELLED ref returns filled: false, active:
  false. The walk's stop-detection relies on the distinction:
  `filled?/2` reads only "filled", so a cancelled stop correctly
  reads as not-filled and the poll does not book a phantom stop
  exit. But `active: false` on an absent ref means "gone, didn't
  fill" — the semantics a real venue's "order not found" must also
  translate to (the Hyperliquid/KuCoin adapters' cancel-already-
  gone handling exists for this same race).
  """

  @behaviour RiptideExecutor.Venue

  # GenServer in name only — see moduledoc "Concurrency shape". It
  # exists to own the named table so the table dies with the test
  # process tree, not to serialize access.
  use GenServer

  # Single named table shared by the whole test node. Named-public:
  # any process can read/write directly, and the name survives
  # across test modules in the same run.
  @table :fake_venue

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    # Idempotent table creation: the suite may start the venue once
    # per test module; a second start finds the table already there.
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :named_table, :public])
      _ -> :ok
    end

    reset()
    {:ok, %{}}
  end

  @doc """
  Wipes all orders AND resets the price to 0.0. Called in every
  test's setup — a leftover resting order from a previous test is
  exactly the kind of cross-test contamination that produces
  order-dependent flaky failures (the ManagedTrade suite's setup
  calls this unconditionally for that reason).

  NOTE the 0.0 sentinel: an order placed while price is 0.0 can
  never be crossed (all ladder levels are > 0), so a test that
  forgets to set_price gets silence, not chaos.
  """
  def reset do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:price, 0.0})
    :ok
  end

  @doc """
  THE control knob. Sets the current market price; every subsequent
  order_status poll re-evaluates all resting orders against it.
  Forced to float (`p * 1.0`) so integer test prices can't produce
  mixed-type arithmetic surprises in the walk's R math.
  """
  def set_price(p), do: :ets.insert(@table, {:price, p * 1.0})

  @doc "Current price — the same number the crossing rules see. For test assertions."
  def price do
    case :ets.lookup(@table, :price) do
      [{_, p}] -> p
      [] -> 0.0
    end
  end

  # Leverage is meaningless without margin — trivial :ok. The walk
  # calls it best-effort before every entry and must not care.
  @impl RiptideExecutor.Venue
  def set_leverage, do: :ok

  # A market order is BORN filled: it stores its kind and the price
  # at placement, and order_status reports it filled forever after.
  # The fill_price is frozen at placement — matching IoC semantics
  # (it executed immediately or died; if it exists, it executed).
  @impl RiptideExecutor.Venue
  def place_market(%{side: side}) do
    ref = ref("mkt")
    :ets.insert(@table, {ref, %{side: side, kind: :market, level: price(), tag: :entry}})
    {:ok, ref}
  end

  # Limits and stops store their LEVEL; nothing is evaluated at
  # placement — crossing is decided lazily, on each poll, against
  # whatever the price is THEN. This laziness is what lets a test
  # place an order far from the market and bring the market to it
  # (or not) later.
  @impl RiptideExecutor.Venue
  def place_limit(%{side: side, price: level, tag: tag}) do
    ref = ref("lmt")
    :ets.insert(@table, {ref, %{side: side, kind: :limit, level: level * 1.0, tag: tag}})
    {:ok, ref}
  end

  @impl RiptideExecutor.Venue
  def place_stop(%{side: side, trigger_price: level, tag: tag}) do
    ref = ref("stp")
    :ets.insert(@table, {ref, %{side: side, kind: :stop, level: level * 1.0, tag: tag}})
    {:ok, ref}
  end

  # Cancel is unconditional :ok — a ref that isn't in the table
  # (already filled, never existed) deletes nothing and still
  # returns :ok, mirroring the real adapters' "already-gone is a
  # fine cancel result" contract. The ratchet races triggers
  # routinely; the fake must tolerate the same race.
  @impl RiptideExecutor.Venue
  def cancel(ref) do
    :ets.delete(@table, ref)
    :ok
  end

  # The heart of the fake. Three cases:
  #   - market: born-filled at its placement price
  #   - limit/stop resting: crossed? evaluated against CURRENT price
  #     — the same poll-to-poll re-evaluation the real walk depends
  #     on; a price that crosses on step 3 but not step 2 fills
  #     exactly when the test says the market got there
  #   - absent ref: filled: false, active: false (cancelled/never-
  #     existed — NOT filled; the walk must never book a phantom
  #     exit off a cancelled order)
  @impl RiptideExecutor.Venue
  def order_status(ref) do
    case :ets.lookup(@table, ref) do
      [{_, %{kind: :market} = o}] ->
        {:ok, %{"filled" => true, "fill_price" => o.level, "active" => false}}

      [{_, o}] ->
        filled = crossed?(o, price())

        {:ok,
         %{
           "filled" => filled,
           "fill_price" => if(filled, do: o.level, else: nil),
           "active" => not filled
         }}

      [] ->
        {:ok, %{"filled" => false, "fill_price" => nil, "active" => false}}
    end
  end

  # The bare match is SAFE here and only here: this order_status can
  # never return {:error, _}. Real adapters must NOT copy it — their
  # version logs errors (the 2026-10-28 silent-poll lesson).
  @impl RiptideExecutor.Venue
  def order_filled?(ref) do
    {:ok, %{"filled" => filled}} = order_status(ref)
    {:ok, filled}
  end

  # Account primitives are stubs — the walk never reads them in its
  # decision path (sizing uses BANKROLL_USD, not balance), so
  # truthful zeros keep any accidental read loud (a 0.0 account
  # value in a test assertion is a bug someone wants to see).
  @impl RiptideExecutor.Venue
  def balance, do: {:ok, %{"accountValue" => 0.0}}

  @impl RiptideExecutor.Venue
  def positions, do: {:ok, []}

  # Mark price == the test's price. Note this makes the fake's stop
  # triggering and the walk's breach check use the SAME reference —
  # which is exactly the consistency the real adapters preserve
  # (venue triggers on the venue's own mark reference).
  @impl RiptideExecutor.Venue
  def mark_price, do: {:ok, price()}

  # The crossing rules — the fake's entire market model in four
  # clauses. Symmetric and total: every (kind, side) pair has
  # exactly one rule, so a malformed order struct fails loudly
  # (FunctionClauseError) instead of silently never filling.
  defp crossed?(%{kind: :limit, side: :sell, level: l}, p), do: p >= l
  defp crossed?(%{kind: :limit, side: :buy, level: l}, p), do: p <= l
  defp crossed?(%{kind: :stop, side: :sell, level: l}, p), do: p <= l
  defp crossed?(%{kind: :stop, side: :buy, level: l}, p), do: p >= l

  # Prefixed refs so a test failure's inspect output is readable at
  # a glance ("fake-stp-42 died" vs "fake-lmt-41") — cheap
  # debuggability for free.
  defp ref(prefix), do: "fake-#{prefix}-#{System.unique_integer([:positive])}"
end

