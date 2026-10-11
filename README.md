# Riptide Executor

This program sits on your computer, listens for trade signals from the
Riptide server, and (once live trading is switched on) places the
trades on KuCoin for you.

**Right now it does NOT trade.** It runs in "dry run" mode: it shows you
every trade it *would* make, in plain text, and sends nothing anywhere.
You need to watch it for a few days first. Nobody flips on real trading
until the output looks right.

You do not need to know any programming language to run this. You need
to be able to open a terminal and paste commands. That's it.

---

## What you need

- A Linux or Mac computer that stays on during market hours
- About 15 minutes of setup
- A **token** from Riptide. Ask them. It's a long random string.
- (Later, for real trading only:) a KuCoin account and API key

---

## Step 1 — Install Elixir

Elixir is the language this program is written in. You need version 1.18
or newer. If you already have it, skip this step. Check with:

    elixir --version

If that says "command not found" or a version below 1.18, install it:

### Ubuntu / Debian

Copy and paste these blocks one at a time. The first installs some
tools (you'll be asked for your password):

    sudo apt update
    sudo apt install -y git curl build-essential autoconf m4 \
      libncurses-dev libssl-dev libwxgtk3.0-gtk3-dev wx-common

The second installs a version manager and then Elixir itself:

    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
    echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
    echo '. "$HOME/.asdf/completions/asdf.bash"' >> ~/.bashrc
    source ~/.bashrc

    asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
    asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git

    asdf install erlang 26.2.5
    asdf install elixir 1.18.3
    asdf global erlang 26.2.5
    asdf global elixir 1.18.3

**Warning:** installing Erlang takes 10–20 minutes. It looks frozen.
It's not. Let it run.

When it's done, check:

    elixir --version

You want to see Elixir 1.18.x and OTP 26.

### Mac

    brew install elixir

That's it.

---

## Step 2 — Get the code

Riptide sends you a download link or a zip. Unzip it, open a terminal
in that folder, or:

    git clone https://github.com/severian1778/riptide-client.git
    cd riptide-client

---

## Step 3 — Configure it

Copy the example settings file:

    cp .env.example .env

Open `.env` in a text editor and fill in the values:

### The token (required, everyone)

    RIPTIDE_API_TOKEN=<paste the token Riptide gave you>
    RIPTIDE_WS_URL=<ask Riptide — they tell you the server address>
    MARKET=futures
    DRY_RUN=true

**Leave DRY_RUN=true.** That is the whole point right now.

### KuCoin keys (only when Riptide says live trading is ready)

KuCoin keys are how the program places trades on YOUR KuCoin account.
Until you add them, the program can't touch your account at all.

To create them, on the KuCoin website (kucoin.com, log in):

1. Click your avatar (top right) → **API Management**
2. Click **Create API**
3. Name it anything (e.g. "riptide")
4. Choose a **passphrase** — you pick it, you'll paste it below.
   Don't lose it.
5. Permissions: check **General** and **Trade** ONLY.
   **Never** enable Withdrawals on this key. The key can place
   trades but can never move money OUT of your account.
6. If your home internet address doesn't change, turn on **IP
   whitelist** and paste your public IP there. Get it by running
   `curl ifconfig.me` in a terminal.
7. Complete the 2FA confirmation.
8. Copy the **API Key**, **Secret**, and your **passphrase**
   IMMEDIATELY. The Secret is shown exactly once. If you lose it,
   delete the key and make a new one — there is no recovery.

Then fill in:

    KUCOIN_API_KEY=<key>
    KUCOIN_API_SECRET=<secret>
    KUCOIN_API_PASSPHRASE=<passphrase>

### The rules about keys and tokens

- Your token and your KuCoin keys live ONLY in your `.env` file on
  YOUR computer. Never in a chat, never in a screenshot, never in git.
- The `.gitignore` already excludes `.env`. Don't fight it.
- If your token leaks: tell Riptide — they kill it in seconds.
- If your KuCoin keys leak: delete the key in KuCoin's API Management
  page immediately and make a new one.

---

## Step 4 — Run it

In the terminal, in the folder:

    ./start.sh

The first run takes a few minutes (it downloads and builds things).
After that it starts in seconds.

You'll see:

    Feed: connected to central server
    Feed: joined predictions:futures — live, waiting for trades

Then it goes quiet. **Quiet is normal.** Trades are rare — some days
there are none. When one comes, you'll see a box like this:

    ═══ DRY RUN — WOULD TRADE ═══
    bullish futures at $100000
    anchor: 2026-10-11T07:46:24Z
    SL:  1.0%
    TP1: 0.5% (half off, stop to breakeven)
    TP2: 2.0% (remainder)
    timeout: 180 min
    Kelly: 0.2  conf: 0.9
    Expected R: 0.16 ± 0.9
    ═════════════════════════════

That box is the trade the system wants to take: direction, entry, where
the stop goes, where the two profit targets go, and how long it would
hold before giving up.

**To stop the program:** press Ctrl-C, then press it again. It stops
cleanly. Run `./start.sh` again whenever you want it back on.

---

## Checking your KuCoin connection (optional, only with keys)

If you've added KuCoin keys and want to confirm they work, run:

    set -a; source .env; set +a
    iex -S mix

then at the prompt:

    RiptideExecutor.Kucoin.Client.account_overview()

If you see a response with `"code" => "200000"`, the connection works.
(You'll also see your balance. Don't screenshot it.) Press Ctrl-C twice
to exit.

This step is optional and read-only — it can't place any orders.

---

## What the lines in the trade box mean

- **bullish / bearish** — which way the trade goes. Bullish = long
  (price up = profit), bearish = short (price down = profit).
- **SL** — stop loss. If price moves against you by this much, the
  trade closes and you lose exactly that back at worst. No more.
- **TP1** — first profit target. Half the position closes here, and the
  stop on the rest moves to your entry price (breakeven). From that
  moment the remaining half cannot lose money.
- **TP2** — second profit target. The other half closes here.
- **timeout** — if neither target is hit within this many minutes, the
  trade closes at whatever the price is.
- **Kelly** — how much of your bankroll the math says to risk on this
  trade. 0.2 = 20%. A value of 0 means don't take this one at all.

---

## When does real trading start?

Not yet. The plan:

1. You run it in dry run for days/weeks. Watch the boxes.
2. When everyone's comfortable, Riptide tells you the real-trading
   version is ready and gives you new instructions.
3. Only then do you flip `DRY_RUN=false` in `.env` — yourself, on
   purpose, with keys you created yourself.

Nothing trades real money until you personally flip that switch.

---

## Problems?

| What you see | What it means | Fix |
|---|---|---|
| `No .env found` | You skipped step 3 | `cp .env.example .env` and fill it in |
| `RIPTIDE_API_TOKEN not set` | Token missing from `.env` | Open `.env`, paste the token |
| `Elixir is not installed` | Step 1 not done (or not done in this terminal) | Redo step 1, then close and reopen your terminal |
| `connected` never appears | Wrong server address, or server is down | Check `RIPTIDE_WS_URL` with Riptide |
| `unauthorized` or repeated reconnects | Token is wrong or was revoked | Ask Riptide for a new token |
| `elixir --version` shows 1.13 or lower | Your system's Elixir is too old | Do the asdf install from step 1 |
| KuCoin error 401 or `40K` codes when checking connection | Key, secret, or passphrase is wrong | Re-check `.env`; if the Secret was never saved, make a new key |
| crashes mentioning KuCoin | KuCoin keys missing from `.env` | Add all three values, or leave them blank (dry run doesn't need them) |
| Warnings about `mint` security advisories | Dependency checker being loud | Harmless, but tell Riptide |

Still stuck? Screenshot the terminal output — the whole thing, not just
the last line — and send it to Riptide.

---

## Quick reference

    ./start.sh        # start it
    Ctrl-C, Ctrl-C    # stop it
    elixir --version  # check your install

