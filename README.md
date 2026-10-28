# Riptide Executor

**The robot that takes the predictions and places the trades.**

```
┌──────────────────┐         ┌───────────────────┐         ┌──────────────┐
│   RIPTIDE SERVER │ websocket│   THIS EXECUTOR   │  orders  │  HYPERLIQUID │
│  finds toxic flow │ ───────> │  decides + manages │ ───────> │   (or KuCoin)│
│  builds ladders   │ ladders  │   every trade      │  BTC perp│              │
└──────────────────┘         └───────────────────┘         └──────────────┘
```

The server watches Bitcoin and finds moments when aggressive money slams
into the market. When it finds one, it sends the executor a **ladder** —
a complete trade plan. The executor's only job is to turn that plan into
real orders and babysit the trade until it's done.

This README explains everything: what each piece does, how to set it up,
how to get the keys, and what buttons to press.

---

## Table of Contents

1. [What This Software Does](#1-what-this-software-does)
2. [The Ladder Trade — In Plain Words](#2-the-ladder-trade--in-plain-words)
3. [Every Module, Explained](#3-every-module-explained)
4. [The Venues (Where Trades Happen)](#4-the-venues-where-trades-happen)
5. [Setup — Step by Step](#5-setup--step-by-step)
6. [Hyperliquid + Rabby Wallet Setup](#6-hyperliquid--rabby-wallet-setup)
7. [Getting a Token from the Riptide API](#7-getting-a-token-from-the-riptide-api)
8. [The .env File — Every Line Explained](#8-the-env-file--every-line-explained)
9. [Running It](#9-running-it)
10. [Basic Operations — The Command Cheat Sheet](#10-basic-operations--the-command-cheat-sheet)
11. [Safety Rules the Code Enforces](#11-safety-rules-the-code-enforces)
12. [When Something Goes Wrong](#12-when-something-goes-wrong)
13. [Appendix: Where the Predictions Come From](#13-appendix-where-the-predictions-come-from)

---

## 1. What This Software Does

Read this sentence slowly, because it's the whole point:

> **The server tells the executor WHAT to trade. The executor decides
> WHETHER and HOW BIG, then places the orders and manages the trade on
> its own — no server needed after that.**

If the server dies mid-trade, nothing bad happens. The trade keeps
running on its own heartbeat (one price check every minute from Binance
directly). The executor is deliberately built so it never depends on
the server once a trade has started.

### What happens when a trade signal arrives

```
1. Server sends a ladder  ──>  Executor checks: "did I already trade this?" (yes → ignore)
2. Executor checks: "is DRY_RUN on?"              (yes → just log it, do nothing)
3. Executor waits for the anchor candle to close  (zero orders until then)
4. Executor checks: "did the candle close against us?"
        yes → trade at HALF size (still trades, never skips)
        no  → trade at full size
5. Executor buys/sells on the venue, instantly places a stop loss
6. Every 5 seconds: "did anything fill yet?"
7. When the take-profit fills → bank half, MOVE THE STOP UP, move to next tier
8. When the time runs out → sell whatever's left, write it all down
9. Every step is written to a permanent journal on disk
```

---

## 2. The Ladder Trade — In Plain Words

Every signal is not one trade. It's a **ladder** of up to 5 tiers,
shortest time horizon first. Think of it like climbing stairs:

```
Tier 1 (3h):  small stop, small target  → first rung
Tier 2 (6h):  bigger target             → second rung
Tier 3 (12h): bigger still              → ...
Tier 4 (24h): ...
Tier 5 (2d):  the top of the ladder
```

**The rules of the climb:**

- **Enter once, at the start.** One buy (or sell) for the whole trade.
- **At each tier's target price:** sell HALF of what you're holding.
  That's called **banking** — taking profit off the table.
- **Every time you bank, the stop loss moves UP** to lock in profit.
  After the first bank you literally cannot lose money on the trade
  anymore.
- **If a tier's time runs out without hitting its target:** the stop
  moves up anyway and you climb to the next tier with more patience.
- **Last tier:** bank once, then just hold the rest until the final
  timer ends, then sell.

**The R unit.** All profit and loss is measured in **R**, where 1R =
the dollar distance of the stop loss. If your stop is $190 away and you
make $190, that's +1R. This makes trades comparable no matter what size
they are. Dollars = R × dollars actually risked. The scoreboard does
this math for you.

**Sizing.** How big is the position?
`kelly × close_mult × quiet_mult`, capped. Kelly is a centuries-old
betting formula — bet more when the odds are good, less when they're
shaky. The server sends its Kelly suggestion; the executor may cut it
in half if the anchor candle closed against the trade direction (a bad
omen), and never bets above the `KELLY_CAP`.

---

## 3. Every Module, Explained

Each file in `apps/riptide_executor/lib/riptide_executor/` does exactly
one job. Here's the map:

| Module | One-sentence job | Read this if... |
|---|---|---|
| **`feed.ex`** | The ear. Connects to the server over websocket, hears ladders, drops duplicates. | you wonder "am I receiving signals?" |
| **`dedupe.ex`** | The memory of "already seen this one." Lives on disk, survives restarts. | the same trade tries to happen twice |
| **`trade_engine.ex`** | The gatekeeper. Decides: dry-run? which venue? how much money? One ladder in, one go/no-go out. | you want to change which venue trades |
| **`trade_supervisor.ex`** | The manager of managers. Starts one trade-worker per ladder, makes sure a crash in one trade can't hurt another. | a trade crashed and you want to know why nothing else broke |
| **`managed_trade.ex`** | **The heart.** One worker that walks ONE trade from entry to exit: queue → enter → bank → move stop → escalate → exit. Every safety rule lives here. | you want to understand the actual trade logic |
| **`market_feed.ex`** | The heartbeat. Every minute it asks Binance for the just-closed candle price and shouts it to all open trades. | trades seem frozen — check if this is alive |
| **`oracle.ex`** | The historian. If a trade starts late and missed the anchor candle, it fetches that candle's close from Binance's history. | a trade starts within 2 minutes of its signal |
| **`ledger.ex`** | The accountant. Writes every decision, fill, and event to disk (DETS files). Survives restarts. Everything not written here didn't happen. | you need proof of what happened |
| **`venue.ex`** | The rulebook. Defines the 10 things any exchange must be able to do. No logic — just the contract. | you're adding a new exchange |
| **`hyperliquid/venue.ex`** | Hyperliquid's translator. Turns generic commands into Hyperliquid's exact API shape. | Hyperliquid order problems |
| **`hyperliquid/client.ex`** | Hyperliquid's handshake. Signs every order cryptographically with your agent key. All the crypto math lives here. | "invalid signature" errors |
| **`kucoin/venue.ex`** + **`kucoin/client.ex`** | Same two jobs, for KuCoin futures. | trading on KuCoin |
| **`fake_venue.ex`** | The practice dummy. A fake exchange for tests — no network, no money, totally predictable. | running the test suite |
| **`status.ex`** | The dashboard. One command that prints everything: is the heartbeat alive, what trades are open, how far along. | you want to see what's happening RIGHT NOW |
| **`track_record.ex`** | The scoreboard. Sums up every closed trade: wins, losses, total R, total dollars. | "are we actually making money?" |
| **`reconcile.ex`** | The detective. Compares three things — the books, the running processes, and what the exchange actually holds — and fixes/report mismatches. | a crash left things in a weird state |
| **`application.ex`** | The ignition switch. Starts everything in the right order. If no API token is set, starts nothing (safe). | boot problems |

---

## 4. The Venues (Where Trades Happen)

A "venue" is the exchange where real orders go. The executor can talk
to more than one — you pick with the `VENUE` line in `.env`.

### Hyperliquid (the default, and what we use)

| Fact | Value |
|---|---|
| What it is | A decentralized perp exchange. Your money stays in your own wallet. |
| Symbol | BTC-PERP (asset id 0 mainnet / 3 testnet) |
| Margin | **Isolated 10x** — each trade locks only its own margin. A blow-up eats one trade, not your account. |
| Stops | Real trigger orders held by the exchange. Fires even if your computer is off. |
| Quirk | No true "market orders" — the executor fakes one with an instant limit order priced 0.5% through the book. You'll never notice. |

**Why we like it:** your funds are never custodied by anyone. The agent
wallet (next section) can trade but **cannot withdraw**. Worst case, a
leaked key loses open margin — never the account.

### KuCoin Futures (built, tested, standing by)

| Fact | Value |
|---|---|
| What it is | A centralized exchange. Money sits in a KuCoin account. |
| Symbol | XBTUSDTM (linear USDT contracts, 0.001 BTC each) |
| Margin | Isolated 5x |
| Stops | Trigger orders, mark-price based |
| Note | Sizes convert to whole contracts; small trades get floored. Set `VENUE=kucoin` to use it. |

### FakeVenue (tests only)

A fake exchange used by the automated tests. Zero network, zero money,
perfectly predictable. Never runs in production.

---

## 5. Setup — Step by Step

Do these in order. Don't skip.

### 5.1 Install the tools

You need **Elixir 1.18+** (which brings Erlang with it).

**Linux (Ubuntu/Debian):**
```bash
sudo apt install erlang elixir
elixir --version   # must say 1.18 or higher
```

**Mac:**
```bash
brew install elixir
```

### 5.2 Get the code

```bash
git clone <your-repo>
cd riptide
```

### 5.3 Install dependencies

From the **umbrella root** (the top folder):

```bash
mix deps.get
mix compile
```

If `mix compile` finishes with no red errors, the code is good.

### 5.4 Create your `.env`

Go to [Section 8](#8-the-env-file--every-line-explained) and build the
file. **Do this before running anything.**

### 5.5 Start the executor

```bash
iex -S mix
```

With `DRY_RUN=true` (the default), it connects, receives signals, and
**logs what it would have done — placing zero orders.** Read those logs
for a day. That's your flight simulator.

---

## 6. Hyperliquid + Rabby Wallet Setup

This is the part people get wrong, so it's spelled out click by click.
We set up **testnet first** — fake money, real code. Only when that's
proven do you repeat it on mainnet.

### 6.1 What the two keys are

Hyperliquid uses a two-wallet trick, and it's genuinely good for you:

| Wallet | What it is | What it can do | Where its key goes |
|---|---|---|---|
| **Master wallet** | Your real Rabby wallet holding the money | Everything — deposits, withdrawals, trading | Only its **address** goes in `.env`. The private key NEVER touches this computer. |
| **Agent wallet** | A throwaway key created just for the bot | Trade only. **Cannot withdraw. Cannot touch your funds.** | Its private key goes in `.env`. This is the key the robot signs with. |

So the robot gets a key that can place orders but is locked out of your
money. This is the whole point of the design.

### 6.2 Testnet walkthrough (do this first)

**Step 1 — Install Rabby.**
Browser extension from [rabby.io](https://rabby.io). Chrome, Brave, or
Firefox.

**Step 2 — Create a wallet.**
"Create a new wallet." Write the seed phrase on **paper**. Not a
screenshot, not a note app. Paper. You'll never need this phrase for
the bot, but it's your master key — lose it, lose everything.

**Step 3 — Get test money.**
Go to `https://app.hyperliquid-testnet.xyz`. Connect Rabby. Click
**Deposit** → there's a faucet/test-fund option that gives you free
test USDC. (Testnet money is worthless; that's the point.)

**Step 4 — Create the agent wallet.**
On the testnet site: **API** tab (top right) → **Approve Agent** (or
"Generate API wallet"). Hyperliquid creates a new agent key and shows
you its **private key**. Rabby will pop up asking you to sign —
approve it.

**Step 5 — Copy the two values.**
- The agent's **private key** (long hex string starting `0x...`) →
  this becomes `HYPERLIQUID_AGENT_KEY`
- Your **master wallet's address** (Rabby → account details → copy
  address, starts `0x...`) → this becomes `HYPERLIQUID_MASTER_ADDRESS`

**Step 6 — Set testnet mode.**
`HYPERLIQUID_TESTNET=true` in `.env`. Done. Start trading with fake
money.

### 6.3 Mainnet (real money) — only after testnet proves out

Identical steps, three differences:

1. Use `https://app.hyperliquid.xyz` (the real site).
2. Fund for real: buy USDC on any exchange → withdraw it **on the
   Arbitrum network** to your Rabby master address → deposit into
   Hyperliquid from the site. (Hyperliquid only accepts Arbitrum USDC.)
3. In `.env`: `HYPERLIQUID_TESTNET=false`.

**Then, before going live:**

- Leave `DRY_RUN=true` for at least a full day of live signals.
- Then `DRY_RUN=false` with a small `BANKROLL_USD`.
- Watch `RiptideExecutor.Status.print()` like a hawk for the first week.

### 6.4 Rules that keep you from getting robbed

- **The seed phrase never goes in `.env`.** Only the agent key does.
  If any tool asks for your seed phrase, it's a scam, full stop.
- **The agent key is a live trading key.** Anyone who has it can open
  and close positions with your margin. Treat it like a loaded weapon:
  `.env` only, never in git, never in Slack, never in a screenshot.
- **Add `.env` to `.gitignore`** (it already is — verify).
- Agents on Hyperliquid **cannot withdraw**. If a key leaks, your
  maximum loss is the margin currently in open trades. That's the fire
  extinguisher.

---

## 7. Getting a Token from the Riptide API

The executor needs a password to hear the server's predictions. That
password is a **bearer token**, and it's issued by the server itself.

### 7.1 Ask whoever runs the server, or run this yourself

On the **server machine** (the one running the Riptide API on port
4003):

```bash
mix riptide_api.create_client --name my-executor
```

It prints something like:

```
API client created: my-executor

Bearer token (shown ONCE — store it now):

    Kj8mP2qR7vN4xC9bL1sT6wZ3yH5fD0gA8eU2iO7pQ4r

Usage:
    curl -H "Authorization: Bearer <token>" http://localhost:4003/api/v1/predictions
```

### 7.2 The rules of the token

- **It is shown exactly once.** Copy it immediately. If you lose it,
  revoke and issue a new one — there is no "remind me."
- It goes into `.env` as `RIPTIDE_API_TOKEN=...`.
- No token in `.env` = the executor starts completely dormant. It won't
  crash, won't connect, won't do anything. That's deliberate, so the
  executor can sit inside the server's own codebase harmlessly.
- A revoked token dies everywhere at once — websocket and web API both
  check the same list.

### 7.3 Tell the executor where the server is

`.env` also needs the server's websocket address:

```
RIPTIDE_WS_URL=ws://SERVER_IP_OR_HOSTNAME:4003/executor/websocket
```

Same machine? `ws://localhost:4003/executor/websocket`. Different
machine? Use its IP or hostname.

### 7.4 Prove it works

Start the executor. Within seconds of connecting you should see in the
log:

```
Feed: connected to central server
Feed: joined predictions:futures — live, waiting for ladders
```

No lines like that = wrong URL or wrong token. Check those two before
anything else.

---

## 8. The .env File — Every Line Explained

The executor reads one file: `.env` at the **umbrella root** (the top
folder of the project). Create it by copying the example and filling it
in. Lines starting with `#` are comments — they do nothing, they're
just for you.

```bash
# ═══════════════════════════════════════════════════════════════
#  RIPTIDE EXECUTOR CONFIGURATION
#  Copy this whole file to .env and fill in the values.
#  NEVER commit this file. NEVER paste it into a chat.
# ═══════════════════════════════════════════════════════════════

# ── 1. THE SERVER CONNECTION ───────────────────────────────────
# The password that lets this executor hear predictions.
# Get it from the server admin (see README section 7).
# Shown once when created. Without it, the executor stays asleep.
RIPTIDE_API_TOKEN=paste-your-token-here

# Where the server lives. Same machine → localhost. Remote → its IP.
RIPTIDE_WS_URL=ws://localhost:4003/executor/websocket

# Which prediction stream to join. The executor now listens to
# futures AND spot anchors (spot anchors are traded on futures).
MARKET=futures

# ── 2. THE BIG RED SWITCH ──────────────────────────────────────
# true  = DRY RUN. Receives and logs everything, sends NO orders. DEFAULT.
# false = LIVE. Real orders. Real money. Double-check everything first.
DRY_RUN=true

# ── 3. WHICH EXCHANGE ──────────────────────────────────────────
# "hyperliquid" or "kucoin"
VENUE=hyperliquid

# ── 4. MONEY SETTINGS ──────────────────────────────────────────
# The capital base used for sizing math. NOT read from the exchange —
# this is the number you declare. Start small on mainnet.
BANKROLL_USD=10000

# Maximum bet fraction. Kelly's suggestion can never exceed this.
# 0.2 = never risk more than 20% of bankroll on one trade.
KELLY_CAP=0.2

# Hard ceiling on position size in BTC, no matter what the math says.
MAX_POSITION_BTC=0.5

# ── 5. HYPERLIQUID ─────────────────────────────────────────────
# true  = testnet (fake money). START HERE.
# false = mainnet (real money).
HYPERLIQUID_TESTNET=true

# The agent wallet's PRIVATE key (0x...). Trade-only, cannot withdraw.
# From Rabby + Hyperliquid API tab. See README section 6.
HYPERLIQUID_AGENT_KEY=0x-your-agent-private-key

# Your master wallet's ADDRESS (0x...). Public info — safe to share.
# This is the account the robot trades on behalf of.
HYPERLIQUID_MASTER_ADDRESS=0x-your-master-wallet-address

# Leverage. 10x isolated is the default. Each trade locks its own
# margin; a liquidation eats one trade, never the account.
HYPERLIQUID_LEVERAGE=10

# ── 6. KUCOIN (only if VENUE=kucoin) ───────────────────────────
# From KuCoin → API Management → Create API (V2 keys, with passphrase).
# Bind the API key to your server's IP address.
KUCOIN_API_KEY=
KUCOIN_API_SECRET=
KUCOIN_API_PASSPHRASE=
KUCOIN_LEVERAGE=5

# ── 7. STORAGE (usually leave alone) ───────────────────────────
# Where the trade journal is written. One folder, four files,
# survives restarts.
LEDGER_DIR=priv/ledger
```

### 8.1 Minimal starter file (testnet, dry-run — copy this)

```bash
RIPTIDE_API_TOKEN=your-token-from-the-server
RIPTIDE_WS_URL=ws://localhost:4003/executor/websocket
MARKET=futures
DRY_RUN=true
VENUE=hyperliquid
HYPERLIQUID_TESTNET=true
HYPERLIQUID_AGENT_KEY=0x-your-agent-key
HYPERLIQUID_MASTER_ADDRESS=0x-your-master-address
BANKROLL_USD=10000
```

That's a complete, safe, sleeping-until-signals configuration.
Everything else has sensible defaults.

### 8.2 How the file gets loaded

You don't need to `source` it or export anything. The project reads
`.env` automatically at startup (see `config/config.exs`). Change the
file → restart the executor → new values apply.

### 8.3 The golden progression

```text
Day 1-3:   DRY_RUN=true,  TESTNET=true     → watch it think
Day 4-7:   DRY_RUN=false, TESTNET=true     → watch it trade fake money
Week 2:    DRY_RUN=false, TESTNET=false, small BANKROLL_USD
Later:     raise BANKROLL_USD only when the scoreboard earns it
```

Never skip steps. Each step exists because someone skipped it before.

---

## 9. Running It

```bash
# from the umbrella root
iex -S mix
```

What you'll see on a healthy start:

```
MarketFeed: connected, first bar in <60s
Feed: connected to central server
Feed: joined predictions:futures — live, waiting for ladders
```

Then, when a signal arrives:

```
═══ LADDER ACCEPTED ═══
bullish futures @ \$80901.8
  3h: SL 0.235%  TP2 0.286%  ...
ManagedTrade: ⏳ QUEUED bullish BTCUSDT — awaiting anchor bar close
ManagedTrade: OPEN bullish BTCUSDT
  qty 0.020 BTC @ \$80879.00   kelly 0.186
  capital at risk \$380.13   stop trigger \$80688.93
```

When a trade takes profit:

```
ManagedTrade: 💰 BANK 3h @ \$81110.20  +1.0R  stop → \$80994.60
```

When a trade ends:

```
ManagedTrade: ═ CLOSED — final_expiry @ \$81154.00  +0.8R on the exit, TOTAL +1.8R
```

**Leaving:** Ctrl+C twice. Open trades keep their exchange-side stop
orders — the exchange holds the stop even while you're logged out.
Restart anytime; the journal picks up where it left off.

**Live code changes while running:** type `recompile` in the IEx prompt.

---

## 10. Basic Operations — The Command Cheat Sheet

Type these inside the running `iex` session. These are the only
commands a normal operator needs.

### See everything at once

```elixir
RiptideExecutor.Status.print()
```

```
╔══════════════════════════════════════════════════════════╗
║  🎛️  RIPTIDE EXECUTOR
║  Oracle   ✅ ALIVE
║     last bar 2026-10-28T04:54:00Z (31s ago)
║     close    \$80930.00
║  ▸ OPEN TRADES (1)
║  🔶 2026-10-28T01:45:00Z  [ladder]
║     tier 1  3h   bar 109/180
║     pos  0.02 BTC   banked +0.0R
║     entry \$80879.00   price \$80930.00   stop \$80688.93
║     [████████████░░░░░░░░]
╚══════════════════════════════════════════════════════════╝
```

Icons: ⏳ waiting to enter · 🔶 in trade, nothing banked · 🟢 in
trade, profit locked · 💀 **books say open but no process is running —
run Reconcile**.

### The money questions

```elixir
# How much money do I have (perps + spot, Hyperliquid's two books)?
RiptideExecutor.Hyperliquid.Venue.print_balance()

# What positions does the exchange actually hold right now?
RiptideExecutor.Hyperliquid.Venue.print_positions()

# Am I winning? Every closed trade, summed.
RiptideExecutor.TrackRecord.print()
```

### The detective (run this after ANY crash or restart)

```elixir
RiptideExecutor.Reconcile.run()
```

It compares the books against reality and fixes bookkeeping ghosts,
then shouts loudly if real money is sitting somewhere with no manager.
**Make this a reflex: restart → `Reconcile.run()` → `Status.print()`.**

### Look inside one trade

Every trade is keyed by `{symbol, market, anchor_timestamp}`. Grab the
key from `Status.print()`, then:

```elixir
key = {"BTCUSDT", "futures", "2026-10-28T01:45:00Z"}

RiptideExecutor.Ledger.get_trade(key)     # the trade's full record
RiptideExecutor.Ledger.fills(key)         # every fill, in order
RiptideExecutor.Ledger.event_log(key)     # the play-by-play of decisions
RiptideExecutor.Ledger.trade_keys()       # all trades ever
```

The event log is the black-box recorder. After any weird outcome,
`event_log` tells you exactly what the trade machine saw and did, in
order.

---

## 11. Safety Rules the Code Enforces

These are not suggestions. They are hard rules baked into
`managed_trade.ex`, and knowing them tells you what the robot will
never do:

1. **It never trades without a stop.** If the exchange refuses the
   stop order, the robot immediately sells the position back. It will
   not hold an unprotected position for even one poll cycle.
2. **The new stop goes up BEFORE the old one comes down.** If
   re-placing the stop fails mid-move, the old stop stays standing.
   There is no moment where a position has zero stops.
3. **It never doubles into the same signal.** Every signal has a
   fingerprint (symbol + market + timestamp). Seen once = never again,
   and the memory survives restarts (it's on disk).
4. **A crashed trade never re-opens itself.** If the robot restarts
   mid-trade, it refuses to re-enter and flags the situation for a
   human instead of blindly re-buying.
5. **It only records exits that actually happened.** The books can't
   show a close the exchange didn't execute. A failed exit retries
   until it works.
6. **Every signal trades — but sizing reacts.** A candle closing
   against the direction doesn't skip the trade; it halves the size.
   Bad omen = smaller bet, never a missed event.
7. **Isolated margin only.** A liquidation can eat one trade's margin,
   never the account.

---

## 12. When Something Goes Wrong

| Symptom | Meaning | What to do |
|---|---|---|
| Nothing in logs after start | Wrong token or wrong websocket URL | Check `RIPTIDE_API_TOKEN` and `RIPTIDE_WS_URL` |
| `Feed: connected` but no trades for a long time | Normal — signals are intermittent (~15/day) | Patience, or check the server is emitting |
| `Oracle: DOWN` in Status | Can't reach Binance for prices | Check network. Trades will coast on last price; fix soon |
| 💀 NOT RUNNING in Status | Books say open, process is gone (usually after a crash) | `RiptideExecutor.Reconcile.run()` — then follow its report |
| `🛑 REFUSING to re-open` in logs | The robot restarted mid-trade and refused to re-buy (by design) | Run Reconcile; manually handle the exchange position |
| `🛑🛑 POSITION UNPROTECTED, MANUAL INTERVENTION REQUIRED` | Both the stop placement AND the emergency flatten failed | **Act now.** Open the Hyperliquid site, close the position by hand |
| `Invalid nonce` (should never appear anymore) | Fixed bug; if you ever see it, report it | — |
| Trades won on the exchange but scoreboard says big loss | An old bug booked $0 fill prices; now fixed | Correct old records via `Ledger.update_trade/2` |

**The universal first response to anything weird:**

```elixir
RiptideExecutor.Reconcile.run()
RiptideExecutor.Status.print()
```

Then read the logs. Every important action is logged in full sentences.

---

## 13. Appendix: Where the Predictions Come From

The executor subscribes to Riptide's proprietary API. The heavy lifting happens on the private server,
The purpose of the client is simply to automated and manage complex trades


---

*Questions? Read the module's own documentation first — every file in
this codebase is documented in plain language at the top
(`@moduledoc`). In IEx, `h RiptideExecutor.ManagedTrade` prints it.*

