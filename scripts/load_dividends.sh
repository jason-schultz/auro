#!/bin/bash
# Fetch every cash dividend from Massive for each fund tested as shares held
# outright (Wealthsimple), through the live engine, scaled to today's
# shares (a payment before a 2:1 split is halved, as the bars are). Load the
# bars first: a big payment the bars already price in (a spin-off) is left
# out. Massive's free plan allows 5 calls a minute and the engine paces
# itself; two calls a symbol (dividends, splits) take about 26 seconds.
# Safe to re-run: each fund's rows are replaced.
#
#   scripts/load_dividends.sh            # every ETF tested for Wealthsimple
#   scripts/load_dividends.sh SPY TLT    # just these

set -u
BASE="${AURO_BASE_URL:-http://localhost:3000}"

if [ "$#" -gt 0 ]; then
  SYMBOLS=("$@")
else
  SYMBOLS=($(docker exec amplyiq-postgres psql -U postgres -d auro -tAc \
    "SELECT massive_ticker FROM instruments
     WHERE asset_class = 'etf' AND test_broker = 'wealthsimple'
       AND massive_ticker IS NOT NULL ORDER BY 1"))
fi

for symbol in "${SYMBOLS[@]}"; do
  answer=$(curl -sS -X POST "$BASE/api/massive/dividends/persist" 2>&1 \
    -H 'content-type: application/json' -d "{\"symbol\":\"$symbol\"}")
  echo "$symbol: $answer"
done
