defmodule RiptideExecutor.Venue do
  @moduledoc """
  The exchange contract the ManagedTrade walks the ladder against.

  This is a BEHAVIOUR — a pure interface. It contains no logic and
  holds no state. Every exchange-specific detail (symbols, precision,
  signing, order-type mapping) lives in the adapter implementing it:

    - `RiptideExecutor.Hyperliquid.Venue` — BTC perp, asset id 0
      (mainnet) / 3 (testnet), IoC-limit "markets", trigger stops
    - `RiptideExecutor.Kucoin.Venue`      — XBTUSDTM linear futures,
      0.001 BTC contract size, mark-price trigger stops
    - `RiptideExecutor.FakeVenue`         — deterministic test double,
      fills against a price the test controls; no network, no timing

  TradeEngine selects the adapter at runtime via the VENUE env
  ("hyperliquid" | "kucoin"); Reconcile reads the same env. A new
  exchange means a new adapter of this behaviour — nothing else in
  the executor changes.

  ## The five capabilities the ladder walk needs

  The ManagedTrade state machine (queue → verdict → entry → walk →
  exit) is only expressible against a venue that provides:

    1. REDUCE-ONLY LIMIT ORDERS — the TP rungs. Each rung banks half
       the remaining position at that tier's tp2. Reduce-only is
       load-bearing: the VENUE, not this client, guarantees the order
       can never open or flip a position, so a race between two
       ladders (or a stale walk) cannot double the book.4^
    2. A CANCEL-REPLACEABLE TRIGGER/STOP — the ratchet. After every
       bank the stop moves up to half that tier's tp2. The walk
       implements the move as cancel-then-place, so the venue must
       accept a stop that can be cancelled and re-placed at a new
       trigger. (Hyperliquid triggers stops on the ORACLE MARK price
       — a median of external venues — so a Hyperliquid-only wick
       will not fire it unless the broader market moves.8^)
    3. FILL POLLING — the state machine advances on FILLS, not on
       order placement. `order_status/1` is polled every @poll_ms;
       an order that was ACCEPTED means nothing until the venue
       reports it executed. "Nothing is shown as filled until the
       venue says so" is the audit rule the ledger inherits.1^
    4. A MARK PRICE READ — the tier-timeout breach check compares
       the last pulse price against the ratcheted stop to decide
       between :timeout_stop and :final_expiry escalation.
    5. LEVERAGE CONFIGURATION — isolated margin, set before every
       entry. Never cross: a liquidation must consume only the
       trade's margin, never the account.

  ## Units and precision contract

  All quantities and prices crossing this interface are FLOATS in
  BASE/QUOTE units exactly as the prediction wire format uses them —
  BTC for qty, USDT for price on the BTC ladders. The caller
  (ManagedTrade) does NO venue-specific math. Each adapter converts
  to its venue's native units internally:

    - Hyperliquid: size decimals 3, price ≤ 5 significant figures
    - KuCoin:      whole contracts of 0.001 BTC, tick 0.1
    - sizes are FLOORED, never rounded up, on a risk-constrained
      system — dust is immaterial, over-position is not

  ## Return contract (universal)

  Every callback returns tagged results:

    - success  → `{:ok, ...}` / `:ok`
    - failure  → `{:error, term()}` — term is adapter-defined and
      OPACITY IS ACCEPTABLE here; the walk treats refusals as
      information (log + record), never as crashes

  Callers must NEVER pattern-match a bare `{:ok, ref} =` on a
  placement result — a rejection that crashes the GenServer is how
  positions end up naked and orphaned (observed live: the duplicate-
  nonce crash of 2026-10-28 cancelled the old stop, died before
  placing the new one, and left a 0.01 BTC position unmanaged).

  ## order_status/1 response shape (the walk depends on this map)

      %{
        "filled"     => boolean(),   # fully executed
        "fill_price" => float()|nil, # nil → caller falls back to its
                                     # own reference; NEVER 0.0
        "active"     => boolean()    # still resting on the venue
      }

  A triggered stop that converted to a market order reports
  fill_price nil — the caller books its trigger price instead.
  Booking a literal 0.0 fill once produced a total of -201.9R on a
  WINNING trade; nil-is-nil is the hard rule that prevents it.
  """

  @typedoc "Opaque venue order identifier. Hyperliquid uses integer
  oids sent as-is; KuCoin uses string order ids. Treat as opaque —
  pass it back to cancel/order_status untouched."
  @type order_ref :: String.t()

  @typedoc "Market order request. `tag` records the walk-leg intent
  for logs and the ledger; the venue ignores it."
  @type market_order :: %{
          side: :buy | :sell,
          qty: float(),
          reduce_only: boolean(),
          tag: :entry | :stop_exit | :timeout_exit | :exit
        }

  @typedoc "Limit order request — the TP rungs. reduce_only MUST be
  true for bank legs: the venue then guarantees the fill can only
  shrink the position, never open or flip it.4^"
  @type limit_order :: %{
          side: :buy | :sell,
          qty: float(),
          price: float(),
          reduce_only: boolean(),
          tag: {:bank, String.t()}
        }

  @typedoc "Stop/trigger order request — the ratchet. The adapter
  maps this to the venue's native trigger primitive (Hyperliquid:
  trigger order, isMarket, tpsl \"sl\"; KuCoin: orderType \"stop\",
  stopPriceType \"MP\")."
  @type stop_order :: %{
          side: :buy | :sell,
          qty: float(),
          trigger_price: float(),
          tag: :stop
        }

  # ==========================================================================
  # Order placement
  # ==========================================================================

  @doc """
  Places a market order (entry, or a reduce-only flatten/exit).

  Adapters WITHOUT a native market primitive synthesize one:
  Hyperliquid sends an immediate-or-cancel limit at a slippage-
  buffered mid; KuCoin sends orderType \"market\". The caller needs
  the FILL to happen now or the refusals to be loud — partial IoC
  behavior is acceptable at entry (size is floored anyway), never at
  a reduce-only exit (a rejected exit must retry, not half-fill).

  Returns `{:ok, order_ref}` when the venue ACCEPTED the order —
  acceptance ≠ fill; poll `order_status/1` for the truth.
  """
  @callback place_market(market_order()) :: {:ok, order_ref()} | {:error, term()}

  @doc """
  Places a resting GTC limit order — the bank/TP rungs.

  A sell rung fills at-or-above `price`, a buy rung at-or-below:
  crossing semantics identical to any canonical book.9^ The rung
  banks half the remaining position when filled; the walk learns of
  the fill ONLY through order_status polling, never from this
  return value.
  """
  @callback place_limit(limit_order()) :: {:ok, order_ref()} | {:error, term()}

  @doc """
  Places a trigger/stop order — the protective ratchet.

  MUST be reduce-only in the adapter (the behaviour's callers always
  intend a close). Trigger semantics are the venue's native ones:
  mark-price on both current adapters — which is also the walk's
  close-breach convention, so the state machine and the venue agree
  on when a stop is "in breach".9^

  The RATCHET is implemented by the caller as cancel(order_ref)
  followed by place_stop/1 at the new level — never in-place
  modification.
  """
  @callback place_stop(stop_order()) :: {:ok, order_ref()} | {:error, term()}

  @doc """
  Cancels a resting order by ref.

  Returns `:ok` even when the order was ALREADY GONE (filled,
  triggered, or never existed) — the ratchet races triggers
  routinely and an already-fired stop must not read as a cancel
  failure. Adapters translate venue-specific "not found" errors
  into :ok.
  """
  @callback cancel(order_ref()) :: :ok | {:error, term()}

  # ==========================================================================
  # Fill polling — the walk advances on these, not on placement acks
  # ==========================================================================

  @doc """
  Boolean convenience: has this order FULLY filled?

  The walk's stop-check uses this; any `{:error, ...}` is treated as
  "not filled" and retried on the next poll. A PARTIAL fill reports
  false — the walk (by design decision, 2026-10-28) advances tiers
  only on complete fills.
  """
  @callback order_filled?(order_ref()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  The full poll: filled? / fill_price / active — see the response
  shape contract in the moduledoc.

  Fill-price fidelity rule: the price returned here is what the
  LEDGER books. Adapters should prefer the venue's actual execution
  price (placement-time avgPx where available) over reconstructed
  values, and MUST report nil rather than a fabricated 0.0 when no
  price is recoverable (triggered-stop market conversions).
  """
  @callback order_status(order_ref()) :: {:ok, map()} | {:error, term()}

  # ==========================================================================
  # Account reads — reconciliation and reporting
  # ==========================================================================

  @doc """
  Account balance snapshot. Shape is adapter-defined (Hyperliquid
  returns %{\"accountValue\" => float}; KuCoin returns the raw
  account-overview map) — consumed by console views, not by the
  walk.
  """
  @callback balance() :: {:ok, map()} | {:error, term()}

  @doc """
  Open positions on the venue, adapter-defined shape.

  Reconcile's ORPHAN check is the critical consumer: a ledger trade
  with no managing process + a venue position = real money nobody
  is walking; + an ERROR from this callback = fail SAFE (assume a
  position may exist, never auto-close the ledger while the
  exchange state is unconfirmed).
  """
  @callback positions() :: {:ok, [map()]} | {:error, term()}

  @doc """
  Current mark price for the traded instrument.

  Used for the tier-timeout breach check and console display. On
  Hyperliquid this is the allMids mid; on KuCoin the venue's official
  mark-price endpoint — the same reference price the venue's own
  triggers use, keeping the walk's breach math and the venue's
  trigger behavior consistent.
  """
  @callback mark_price() :: {:ok, float()} | {:error, term()}

  @doc """
  Configures ISOLATED leverage for the traded symbol, before every
  entry.

  Never cross: liquidation must consume only the trade's allocated
  margin. KuCoin sets leverage per-order instead and returns :ok
  trivially; Hyperliquid sends updateLeverage (ISOLATED,
  HYPERLIQUID_LEVERAGE, default 10). Best-effort by contract — the
  walk logs a failure and proceeds; leverage config failure must
  not block a trade whose stop is already sized for the risk.
  """
  @callback set_leverage() :: :ok | {:error, term()}
end

