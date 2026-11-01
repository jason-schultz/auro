#!/usr/bin/env bash
# Nightly backup of the auro database (Homebrew Postgres on this Mac).
#
# Run by launchd every night at 03:00 local time
# (~/Library/LaunchAgents/ca.carbonandfire.auro.backup.plist); a night the Mac
# was asleep runs when it wakes. Safe to run by hand any time.
#
# Each backup is one compressed file, ~/Backups/auro/auro-YYYY-MM-DD.dump,
# written under a temporary name and kept only once Postgres can read it back.
# The newest KEEP files are kept, older ones deleted.
#
# Restore one into a fresh database:
#   createdb auro_restored
#   pg_restore -d auro_restored -j 8 --no-owner ~/Backups/auro/auro-YYYY-MM-DD.dump
set -euo pipefail

BIN=/opt/homebrew/opt/postgresql@18/bin
DIR="$HOME/Backups/auro"
KEEP=14

mkdir -p "$DIR"
file="$DIR/auro-$(date +%Y-%m-%d).dump"
tmp="$file.partial"

echo "$(date '+%F %T') backing up auro to $file"
"$BIN/pg_dump" -d auro -Fc -f "$tmp"
# A dump Postgres can't list is no backup: keep the last good one instead.
"$BIN/pg_restore" --list "$tmp" > /dev/null
mv "$tmp" "$file"
echo "$(date '+%F %T') done: $(du -h "$file" | cut -f1)"

ls -1t "$DIR"/auro-*.dump | tail -n +$((KEEP + 1)) | while IFS= read -r old; do
  echo "$(date '+%F %T') removing $old"
  rm -f "$old"
done
