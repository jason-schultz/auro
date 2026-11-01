#!/usr/bin/env bash
# One-time setup for running Auro as launchd services on this Mac. Safe to run
# again: it never overwrites settings, only adds what's missing and rewrites
# the launchd entries.
#
#   ~/Services/auro/
#     src/              a clone of the GitHub repo that deploys build from
#     releases/<commit>/engine/{auro,auro-tester}, releases/<commit>/opus/
#     current ->        the running release
#     shared/engine/    the engine's .env and logs (-> ~/Library/Logs/auro/engine)
#     shared/tester/    the tester's .env (same file) and logs
#     shared/opus.env   Opus's settings
#   ~/Library/LaunchAgents/ca.carbonandfire.auro.{engine,tester,opus}.plist
#
# Then `scripts/deploy.sh` builds main and starts the services.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME/Services/auro"
LOGS="$HOME/Library/Logs/auro"
AGENTS="$HOME/Library/LaunchAgents"

mkdir -p "$HOME_DIR/releases" "$HOME_DIR/shared/engine" "$HOME_DIR/shared/tester" \
  "$LOGS/engine" "$LOGS/tester" "$LOGS/opus"

if [ ! -d "$HOME_DIR/src/.git" ]; then
  git clone "$(git -C "$REPO" remote get-url origin)" "$HOME_DIR/src"
fi

# The engine and tester read .env from their working folder and write logs/
# there; each gets its own folder, so neither rotates the other's logs away.
if [ ! -f "$HOME_DIR/shared/engine/.env" ]; then
  cp "$REPO/auro_be/.env" "$HOME_DIR/shared/engine/.env"
fi
ln -sfn "$HOME_DIR/shared/engine/.env" "$HOME_DIR/shared/tester/.env"
ln -sfn "$LOGS/engine" "$HOME_DIR/shared/engine/logs"
ln -sfn "$LOGS/tester" "$HOME_DIR/shared/tester/logs"

# Opus's settings: the dev ones from opus/.env, plus what a release needs.
OPUS_ENV="$HOME_DIR/shared/opus.env"
if [ ! -f "$OPUS_ENV" ]; then
  {
    cat "$REPO/opus/.env"
    echo
    echo "export DATABASE_URL=\"postgres://postgres:postgres@localhost:5432/auro\""
    echo "export SECRET_KEY_BASE=\"$(openssl rand -base64 48 | tr -d '\n')\""
    echo "export PHX_SERVER=true"
    echo "export PHX_HOST=localhost"
    echo "export PORT=4321"
    echo "export OPUS_LOG_DIR=\"$LOGS/opus\""
  } > "$OPUS_ENV"
fi
chmod 600 "$HOME_DIR/shared/engine/.env" "$OPUS_ENV"

# One launchd entry per service: started at login, restarted if it stops.
write_agent() { # label, working dir, stdout, stderr, program args...
  local label="$1" dir="$2" out="$3" err="$4"
  shift 4
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
EOF
    for arg in "$@"; do echo "    <string>$arg</string>"; done
    cat <<EOF
  </array>
  <key>WorkingDirectory</key>
  <string>$dir</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$out</string>
  <key>StandardErrorPath</key>
  <string>$err</string>
</dict>
</plist>
EOF
  } > "$AGENTS/$label.plist"
  plutil -lint -s "$AGENTS/$label.plist"
}

# The engine and tester log to their own rotating files (and to stdout,
# which is dropped here); stderr keeps a crash's last words.
write_agent ca.carbonandfire.auro.engine "$HOME_DIR/shared/engine" \
  /dev/null "$LOGS/engine.err.log" "$HOME_DIR/current/engine/auro"
write_agent ca.carbonandfire.auro.tester "$HOME_DIR/shared/tester" \
  /dev/null "$LOGS/tester.err.log" "$HOME_DIR/current/engine/auro-tester"
# Opus logs to $LOGS/opus/opus.log (rotating); stdout has only its start-up.
write_agent ca.carbonandfire.auro.opus "$HOME_DIR" \
  "$LOGS/opus.out.log" "$LOGS/opus.out.log" \
  /bin/bash -c "set -a; . '$OPUS_ENV'; set +a; exec '$HOME_DIR/current/opus/bin/opus' start"

echo "Installed. Stop any engine, tester or Opus running in a terminal, then run scripts/deploy.sh."
