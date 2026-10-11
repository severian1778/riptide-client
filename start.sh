#!/usr/bin/env bash
# Starts the Riptide executor. Loads .env, checks Elixir exists, runs.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Copy .env.example to .env and fill it in:"
  echo "  cp .env.example .env && nano .env"
  exit 1
fi

set -a
source .env
set +a

if ! command -v mix >/dev/null 2>&1; then
  echo "Elixir is not installed. Install it with:"
  echo "  https://elixir-lang.org/install.html"
  exit 1
fi

echo "Building (first run takes a few minutes)..."
mix deps.get
mix compile

echo "Starting executor. Ctrl-C twice to stop."
exec mix run --no-halt

