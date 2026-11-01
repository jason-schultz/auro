#!/usr/bin/env bash
# Start a dev Opus from this working copy, with its settings from opus/.env
# (Elixir doesn't read .env files by itself), on http://localhost:4322 with
# the iex console and hot reload. It shows pages and runs nothing on its own:
# the service (scripts/deploy.sh, port 4321) runs the jobs and account
# workers (config/dev.exs). Pages still act on the real system when you
# click: switching a strategy, starting a test.
#
# opus/.env holds one `export NAME=value` per line. What Opus reads in dev:
#   OANDA_API_KEY, OANDA_ACCOUNT_ID, OANDA_BASE_URL  OANDA account (reconciler, reads)
#   DISCORD_WEBHOOK_URL                              alerts to Discord
#   AURO_BASE_URL, AURO_TESTER_URL                   the engine; default
#                                                    localhost:3000 and :3001
# The database is set in opus/config/dev.exs (localhost:5432/auro).
set -euo pipefail

OPUS="$(cd "$(dirname "$0")/../opus" && pwd)"
cd "$OPUS"

if [ ! -f .env ]; then
  echo "opus/.env is missing" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# Elixir and Erlang come from asdf, whatever the shell has set up.
export PATH="$HOME/.asdf/shims:/opt/homebrew/bin:$PATH"

exec iex -S mix phx.server
