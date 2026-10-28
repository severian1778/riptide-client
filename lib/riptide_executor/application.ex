defmodule RiptideExecutor.Application do
  @moduledoc """
  Local trade executor. Connects to the Riptide prediction feed and
  manages ladder trades on the venue named by VENUE (hyperliquid |
  kucoin). DRY_RUN=false sends real orders.

  ## The token gate — why children can be empty

  When RIPTIDE_API_TOKEN is unset, NO children are started — the
  supervisor comes up with an empty list and the app idles. This
  lets the executor sit in the umbrella tree on the server box
  without crashing the server: one compiled codebase serves both
  the dev laptop (token set, trading) and the server host (token
  unset, dormant). The gate is presence-only (`if env`), not
  validity — an INVALID token fails later, in the Feed's connect
  loop, which retries every 5s forever rather than crashing. A
  dormant executor and a misconfigured one are both non-crashing
  states by design.

  Note what the gate does NOT protect: every module's own
  fetch_env! reads for VENUE credentials (HYPERLIQUID_AGENT_KEY,
  KUCOIN_API_KEY) only fire when a trade actually executes, never
  at boot. Boot with a token and bad venue keys is a running system
  that logs rejections — safe to ship, debug in place.

  ## Startup ordering — load-bearing, do not reorder

  The child list is sequenced so that every process's dependencies
  exist before it can first use them:

    1. Finch (named RiptideExecutor.Finch) — the HTTP pool used by
       Oracle, MarketFeed, and both venue clients. FIRST, because
       MarketFeed's first tick fires within milliseconds of init.
    2. Ledger — the DETS tables. Everything downstream writes to it
       (Feed records trades on its first message; the registries'
       contents are meaningless without it), and ManagedTrade's
       never-stack guard reads it. Also FIRST among the state
       because a Ledger crash-looping with the tree in :one_for_one
       would be the one failure that cascades — starting it first
       surfaces a corrupt LEDGER_DIR immediately at boot, where it
       belongs.
    3. The two Registries — TradeRegistry (:unique, the walk-name
       registry ManagedTrade/Status/Reconcile resolve through) and
       PulseRegistry (:duplicate, MarketFeed's broadcast target).
       Both must exist before any process registers into them:
       Registry.register/3 on a missing registry raises, which
       would kill whichever process lost the race.
    4. MarketFeed — the pulse heartbeat. Registered into
       PulseRegistry implicitly by its subscribers; it must be up
       before any trade subscribes, and its first tick goes out
       immediately at init.
    5. TradeSupervisor — the DynamicSupervisor that will host walk
       processes. Empty at boot; exists so TradeEngine has a named
       target the moment the Feed delivers the first ladder.
    6. Feed — LAST, deliberately. It is the ignition: once it
       joins, backfilled ladders flow to TradeEngine and real
       trades can start within seconds. Everything it needs
       (Finch, Ledger, registries, supervisor) is guaranteed up by
       the time the first message can possibly arrive, because
       Supervisor.start_link starts children strictly in list
       order and the Feed cannot join until its own init completes.

  ## Restart strategy — :one_for_one

  Children are independent by construction: a MarketFeed outage
  must not restart the Ledger (it would be pointless churn against
  DETS), and a Feed outage must not touch open trades (walks run
  on pulses, not the prediction channel). One-for-one restarts each
  failed child alone; the one coupling that exists — trades NEED
  MarketFeed's pulses — is tolerated as a known degraded mode
  (walks freeze, timeouts stall) rather than a crash cascade,
  because a feed restart is faster and safer than restarting every
  walk into its never-stack refusal.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("RIPTIDE_API_TOKEN") do
        [
          # 1. Shared HTTP pool — name matters: every client calls
          #    Finch.request(_, RiptideExecutor.Finch) by name.
          {Finch, name: RiptideExecutor.Finch},
          # 2. Durable state — DETS tables open here; first writer
          #    is safe the moment this returns.
          RiptideExecutor.Ledger,
          # 3. The two registries — :unique for walk names (one
          #    process per dedupe key), :duplicate for the pulse
          #    broadcast (many subscribers, one key :minute).
          {Registry, keys: :unique, name: RiptideExecutor.TradeRegistry},
          {Registry, keys: :duplicate, name: RiptideExecutor.PulseRegistry},
          # 4. The heartbeat — subscribes begin as walks start.
          RiptideExecutor.MarketFeed,
          # 5. The walk host — empty until the first ladder lands.
          RiptideExecutor.TradeSupervisor,
          # 6. The front door — last, so the world it exposes is
          #    fully built before the first signal can arrive.
          RiptideExecutor.Feed
        ]
      else
        # Dormant mode: supervisor with no children. The app is
        # "running" from the umbrella's perspective but does
        # nothing and contacts nothing.
        []
      end

    opts = [strategy: :one_for_one, name: RiptideExecutor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

