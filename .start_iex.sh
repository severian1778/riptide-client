#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found."
  exit 1
fi

set -a
source .env
set +a

mix deps.get
mix compile

echo "Starting executor in iex. Ctrl-C twice to stop."
exec iex -S mix run --no-halt
