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

- A computer that stays on during market hours (Linux, Mac, or Windows
  — see the Windows note in Step 1)
- About 15 minutes of setup
- A **token** from Riptide. Ask them. It's a long random string.
- (Later, for real trading only:) a KuCoin account and API key

---

## Step 1 — Install Elixir

Elixir is the language this program is written in. If you already have
version 1.18 or newer, skip this step. Check with:

    elixir --version

If that says "command not found" or a version below 1.18, install it.

### Windows

The program is a Linux/Mac program, but Windows runs it fine through
**WSL** (Windows Subsystem for Linux). You must use WSL — the native
Windows version of Elixir will NOT work with this program, because the
startup scripts are Linux scripts.

1. Open **PowerShell as Administrator** (right-click the Start button →
   "Terminal (Admin)").
2. Paste this and press Enter:

       wsl --install

3. Restart the computer when it asks. On restart, a window asks you to
   pick a username and password for Ubuntu. Pick anything, remember it.
4. A black Ubuntu terminal appears. Everything below in this README —
   every "open a terminal and paste" step — happens **inside that
   Ubuntu terminal**, not PowerShell. Open it any time from the Start
   menu by typing "Ubuntu".

Once you're in the Ubuntu terminal, follow the Ubuntu instructions
below exactly like a Linux user.

### Ubuntu / Debian

Copy and paste these blocks **one at a time**. This first one installs
the tools needed to build everything (you'll be asked for your password):

    sudo apt update
    sudo apt install -y git curl unzip build-essential autoconf m4 \
      libncurses-dev libssl-dev libwxgtk3.2-dev libwxgtk-webview3.2-dev \
      libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev \
      xsltproc fop libxml2-utils wx-common

**Note:** older guides say `libwxgtk3.0-gtk3-dev`. On Ubuntu 24.04 and
Debian 12+ that package no longer exists — it is `libwxgtk3.2-dev` now,
which is what's written above. If the install says it can't find one of
the packages, run:

    apt search libwxgtk | grep dev

and install whichever version number it lists instead.

This second one installs the version manager and then Elixir itself:

    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.20.2
    echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
    echo '. "$HOME/.asdf/completions/asdf.bash"' >> ~/.bashrc
    source ~/.bashrc

    asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
    asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git

    asdf install erlang latest
    asdf install elixir latest
    asdf set --home erlang latest
    asdf set --home elixir latest

(If `asdf set` says "unknown command", your asdf is an older release —
use `asdf global erlang latest` and `asdf global elixir latest` instead.
Both do the same thing.)

**Warning:** installing Erlang takes 10–20 minutes and it looks frozen.
It's not. Let it run. If it stops with a "missing library" error, you
skipped the first block above — run it, then run `asdf install erlang
latest` again.

When it's done, check:

    elixir --version

You want Elixir 1.18 or newer. If Elixir commands crash immediately on
startup, your Elixir was built for a different Erlang — run:

    erl -version

note the number after "OTP" in the output (e.g. OTP 27), then run:

    asdf install elixir latest-otp-27
    asdf set --home elixir latest-otp-27

(replace 27 with whatever number you saw).

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

Open `.env` in a text editor and fill in the values.

**One important rule when editing `.env`: put every value you paste in
single quotes.** Like this:

    RIPTIDE_API_TOKEN='abc123...long string'

If your password or token contains a `$` (money symbols are common in
generated passwords), leaving it unquoted breaks the program at startup
with a confusing error like `unbound variable`. Single quotes prevent
that. Always use them.

### The token (required, everyone)

    RIPTIDE_API_TOKEN='<paste the token Riptide gave you>'
    RIPTIDE_WS_URL='<the server address Riptide gives you>'
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

Then fill in, in single quotes:

    KUCOIN_API_KEY='<key>'
    KUCOIN_API_SECRET='<secret>'
    KUCOIN_API_PASSPHRASE='<passphrase>'

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

## Peeking inside while it runs (the "console")

The normal way to run this (`./start.sh`) shows you trades, but you
can't type commands to it. There's a second way to start it that gives
you an interactive console **with the program running inside it** —
like having the dashboard and a steering wheel at the same time.

**Important: run only ONE at a time.** Don't run `start.sh` and the
console at the same time — two executors on the same account will fight
over trades. Stop one before starting the other.

First time only, create the console launcher (paste this whole block):

    cat > start_iex.sh << 'EOF'
    #!/usr/bin/env bash
    # Starts the executor with an interactive console.
    set -euo pipefail
    cd "$(dirname "$0")"

    if [ ! -f .env ]; then
      echo "No .env found. Run: cp .env.example .env"
      exit 1
    fi

    set -a
    source .env
    set +a

    mix deps.get
    mix compile

    echo "Starting executor with console. Ctrl-C twice to stop."
    exec iex -S mix run --no-halt
    EOF
    chmod +x start_iex.sh

After that, starting the console is just:

    ./start_iex.sh

You'll see the same "Feed: connected" lines, plus a prompt that looks
like:

    iex(1)>

That prompt is waiting for you to type commands. Type a command, press
Enter, see the answer.

### Things you can type at the iex> prompt

**Check your KuCoin account works** (needs keys in `.env`, is
read-only, cannot place orders):

    RiptideExecutor.Kucoin.Client.account_overview()

If the answer contains `"code" => "200000"`, the connection works.
(You'll also see your balance. Don't screenshot it.)

**List every check command the client knows.** If you're unsure what
else you can ask, type this and read the list:

    h RiptideExecutor.Kucoin.Client

Anything listed there can be called the same way:
`RiptideExecutor.Kucoin.Client.<name>()`.

**Leaving the console:** press Ctrl-C, then press it again. Same as the
normal mode.

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
| `.env: line N: ...: unbound variable` | A `$` in a password being eaten | Put that value in single quotes in `.env` |
| `Elixir is not installed` | Step 1 not done (or not done in this terminal) | Redo step 1, then close and reopen your terminal |
| Erlang build says missing `wx-config` or similar | Build libraries missing | Run the first `sudo apt install` block from Step 1, then retry |
| `Elixir commands crash on startup` | Elixir built for a different Erlang | See the OTP fix in Step 1 (`latest-otp-NN`) |
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

    ./start.sh         # start it (normal mode)
    ./start_iex.sh     # start it with the console
    Ctrl-C, Ctrl-C     # stop it (both modes)
    elixir --version   # check your install

On the console:

    RiptideExecutor.Kucoin.Client.account_overview()   # KuCoin connection check
    h RiptideExecutor.Kucoin.Client                    # list all check commands


