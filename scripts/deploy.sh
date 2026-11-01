#!/usr/bin/env bash
# Build a commit (default: origin/main) and run it as the services.
#
#   scripts/deploy.sh            deploy what's merged to main
#   scripts/deploy.sh <ref>      deploy a branch, tag or commit
#   scripts/deploy.sh --rollback switch back to the previous release
#
# Builds into ~/Services/auro/releases/<commit>/ while the running services
# carry on, asks before running any migration the database hasn't run (and
# stops if you say no), points `current` at the new release, restarts the engine, tester
# and Opus, and checks each answers. If one doesn't, it switches back to the
# release that was running and restarts that. The five newest releases are
# kept. Setup first: scripts/install_services.sh.
set -euo pipefail

HOME_DIR="$HOME/Services/auro"
SRC="$HOME_DIR/src"
LABELS=(ca.carbonandfire.auro.tester ca.carbonandfire.auro.engine ca.carbonandfire.auro.opus)
CHECKS=(http://127.0.0.1:3001/api/health http://127.0.0.1:3000/api/health http://127.0.0.1:4321/)
PORTS=(3001 3000 4321)
DOMAIN="gui/$(id -u)"
export PATH="$HOME/.asdf/shims:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

say() { echo "[deploy] $*"; }

[ -d "$SRC/.git" ] || { say "run scripts/install_services.sh first"; exit 1; }

previous="$(readlink "$HOME_DIR/current" 2>/dev/null || true)"

switch_to() { # release folder
  ln -sfn "$1" "$HOME_DIR/current.new"
  mv -fh "$HOME_DIR/current.new" "$HOME_DIR/current"
}

restart_all() {
  for label in "${LABELS[@]}"; do
    if launchctl print "$DOMAIN/$label" > /dev/null 2>&1; then
      launchctl kickstart -k "$DOMAIN/$label"
    else
      launchctl bootstrap "$DOMAIN" "$HOME/Library/LaunchAgents/$label.plist"
    fi
  done
}

# The process listening on a port, and the one launchd runs for a label.
listener() { lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
service_pid() { launchctl print "$DOMAIN/$1" 2>/dev/null | awk '/^\tpid = / {print $3}'; }

# Anything on the services' ports that isn't the service (an engine or Opus
# left running in a terminal) would keep the service from starting while
# answering its health check in its place.
ports_free_for_services() {
  local i pid
  for i in "${!LABELS[@]}"; do
    pid="$(listener "${PORTS[$i]}")"
    if [ -n "$pid" ] && [ "$pid" != "$(service_pid "${LABELS[$i]}")" ]; then
      say "port ${PORTS[$i]} is held by another process: $(ps -o command= -p "$pid" | cut -c1-80)"
      say "stop it (an engine, tester or Opus still running in a terminal?), then deploy again"
      return 1
    fi
  done
}

healthy() { # each service answers within 90 seconds, and it's the service
  local i tries
  for i in "${!LABELS[@]}"; do
    tries=0
    until curl -fsS -o /dev/null --max-time 5 "${CHECKS[$i]}" &&
      [ "$(listener "${PORTS[$i]}")" = "$(service_pid "${LABELS[$i]}")" ]; do
      tries=$((tries + 1))
      [ "$tries" -ge 30 ] && { say "no answer from ${LABELS[$i]} at ${CHECKS[$i]}"; return 1; }
      sleep 3
    done
    say "ok: ${CHECKS[$i]}"
  done
}

if [ "${1:-}" = "--rollback" ]; then
  older="$(ls -1dt "$HOME_DIR"/releases/*/ | sed 's:/$::' | grep -vx "$previous" | head -1)"
  [ -n "$older" ] || { say "no earlier release to go back to"; exit 1; }
  say "rolling back to $(basename "$older")"
  ports_free_for_services || exit 1
  switch_to "$older"
  restart_all
  healthy
  exit
fi

ref="${1:-origin/main}"
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --detach "$ref"
sha="$(git -C "$SRC" rev-parse --short HEAD)"
release="$HOME_DIR/releases/$sha"
say "deploying $sha: $(git -C "$SRC" log -1 --format=%s)"

if [ ! -f "$release/.built" ]; then
  rm -rf "$release"
  mkdir -p "$release/engine"

  say "building the engine and tester"
  (cd "$SRC/auro_be" && cargo build --release --bins --quiet)
  cp "$SRC/auro_be/target/release/auro" "$SRC/auro_be/target/release/auro-tester" "$release/engine/"

  say "building Opus"
  (
    cd "$SRC/opus"
    export MIX_ENV=prod
    mix deps.get --only prod > /dev/null
    mix compile --warnings-as-errors > /dev/null
    mix assets.deploy > /dev/null
    mix release --overwrite --quiet --path "$release/opus"
  )
  touch "$release/.built"
fi

# Migrations run only when you say so: this release's ones the database
# hasn't run are listed, and a y or yes runs them (from the release's
# source, with the service's settings) before anything restarts.
pending="$(comm -23 \
  <(ls "$SRC/opus/priv/repo/migrations" | grep -oE '^[0-9]+' | sort) \
  <(psql -d auro -Atc 'select version from schema_migrations' | sort))"
if [ -n "$pending" ]; then
  say "migrations not run yet:"
  for version in $pending; do
    say "  $(ls "$SRC/opus/priv/repo/migrations" | grep "^$version")"
  done
  read -r -p "[deploy] run them now? [y/N] " answer
  case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
    y | yes)
      (
        cd "$SRC/opus"
        set -a
        # shellcheck disable=SC1091
        . "$HOME_DIR/shared/opus.env"
        set +a
        MIX_ENV=prod mix ecto.migrate
      )
      ;;
    *)
      say "not run. Nothing was restarted; deploy again when you're ready."
      exit 1
      ;;
  esac
fi

ports_free_for_services || exit 1
switch_to "$release"
restart_all
if healthy; then
  say "running $sha"
else
  if [ -n "$previous" ] && [ "$previous" != "$release" ]; then
    say "switching back to $(basename "$previous")"
    switch_to "$previous"
    restart_all
    healthy || say "the previous release doesn't answer either: check ~/Library/Logs/auro"
  fi
  exit 1
fi

# Keep the five newest releases, and whatever was running before this one.
ls -1dt "$HOME_DIR"/releases/*/ | sed 's:/$::' | tail -n +6 | while IFS= read -r old; do
  [ "$old" = "$previous" ] || rm -rf "$old"
done
