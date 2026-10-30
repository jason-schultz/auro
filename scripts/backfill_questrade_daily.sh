#!/bin/bash
# Load daily bar history from Questrade for every ETF in the instruments
# table, through the live engine (it holds the Questrade connection). Bars
# are split-adjusted but NOT dividend-adjusted. Safe to re-run: the store
# overwrites identical rows. Needs the live engine built with the
# `from`/`to` window on /api/questrade/candles/persist.
#
#   scripts/backfill_questrade_daily.sh            # every ETF, from 1995
#   scripts/backfill_questrade_daily.sh SPY TLT    # just these

set -u
BASE="${AURO_BASE_URL:-http://localhost:3000}"
FROM="${FROM:-1995-01-01}"
WINDOW_DAYS=700

if [ "$#" -gt 0 ]; then
  SYMBOLS=("$@")
else
  SYMBOLS=($(docker exec amplyiq-postgres psql -U postgres -d auro -tAc \
    "SELECT questrade_symbol FROM instruments
     WHERE asset_class = 'etf' AND questrade_symbol IS NOT NULL ORDER BY 1"))
fi

today=$(date +%Y-%m-%d)

for symbol in "${SYMBOLS[@]}"; do
  start="$FROM"
  total=0
  while [[ "$start" < "$today" || "$start" == "$today" ]]; do
    end=$(date -j -v+"${WINDOW_DAYS}"d -f %Y-%m-%d "$start" +%Y-%m-%d)
    [[ "$end" > "$today" ]] && end="$today"
    answer=$(curl -s -X POST "$BASE/api/questrade/candles/persist" \
      -H 'content-type: application/json' \
      -d "{\"symbol\":\"$symbol\",\"granularity\":\"D\",\"from\":\"$start\",\"to\":\"$end\"}")
    stored=$(echo "$answer" | sed -n 's/.*"candles_stored":\([0-9]*\).*/\1/p')
    if [ -z "$stored" ]; then
      echo "$symbol $start..$end: $answer"
    else
      total=$((total + stored))
    fi
    start=$(date -j -v+1d -f %Y-%m-%d "$end" +%Y-%m-%d)
    sleep 1
  done
  first=$(docker exec amplyiq-postgres psql -U postgres -d auro -tAc \
    "SELECT min(timestamp)::date FROM candles WHERE instrument = '$symbol' AND granularity = 'D'")
  echo "$symbol: $total bars stored, history from $first"
done
