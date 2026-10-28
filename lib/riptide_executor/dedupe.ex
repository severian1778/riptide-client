defmodule RiptideExecutor.Dedupe do
  @moduledoc """
  Seen-set keyed on (symbol, market_type, anchor_ts). Now DETS-backed
  via the Ledger: the feed is at-least-once, and restart reconciliation
  needs to know what was already traded, not just what this session saw.
  Kept as a module so Feed's call sites don't change.

  ## Why this module exists at all (it's two one-line functions)

  It is an ANTI-CORRUPTION SEAM, not a wrapper for wrapping's sake.
  Dedupe was originally an in-memory ETS/MapSet implementation with
  this exact two-function surface; when the at-most-once guarantee
  had to survive restarts, the implementation moved wholesale into
  the Ledger's :exec_seen DETS table — and because every call site
  went through this module, the change touched exactly one file.
  Nothing outside Dedupe and Ledger knows where "seen" lives.

  The practical consequence for future sessions: if the seen-set
  storage ever moves again (pruning, TTLs, a real database), the
  contract to preserve is precisely this pair:

      seen?(symbol, market, ts)  → boolean
      mark(symbol, market, ts)   → :ok, idempotent

  ## The key — three separate arguments, one triple

  The three components arrive as SEPARATE arguments and are bundled
  into the canonical tuple HERE, at the boundary. This mirrors the
  Feed's natural shape (a ladder map has symbol, market_type, and
  anchor_ts as sibling fields) while ensuring the tuple handed to
  the Ledger is IDENTICAL to the dedupe key used everywhere else
  (ledger record key, registry name, supervisor child id). One
  bundling site means no call site can accidentally build the key
  with the elements in a different order — a swapped (market, ts)
  tuple would silently dedupe against the wrong trades.

  ## Semantics, pinned

    - mark is called BEFORE TradeEngine.execute in the Feed's trade
      path (crash between them loses one signal; the reverse order
      could double-trade) — so seen? == true does NOT imply the
      trade actually executed, only that a decision was made about
      it. This is the deliberate at-most-once bias: never twice,
      accept losing one.
    - There is no unmark, no TTL, no pruning. The table grows
      forever, one row per signal — at this feed's volume that is
      bytes per day, and the absence of eviction rules is itself a
      correctness feature (nothing can expire and allow a re-trade).
  """

  # Thin delegation, unqualified: the two calls are the module's
  # entire body. Kept non-pipelined (direct call syntax) so grep for
  # "Ledger.seen?" style flows lands here cleanly.
  def seen?(symbol, market, ts), do: RiptideExecutor.Ledger.seen?({symbol, market, ts})

  def mark(symbol, market, ts), do: RiptideExecutor.Ledger.mark_seen({symbol, market, ts})
end

