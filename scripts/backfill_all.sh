#!/bin/bash

INSTRUMENTS=(
    # Forex - majors
    "EUR_USD" "GBP_USD" "USD_JPY" "AUD_USD" "USD_CAD" "NZD_USD"
    # Forex - crosses
    "EUR_JPY" "EUR_GBP" "EUR_CHF" "EUR_CAD" "EUR_AUD"
    "GBP_JPY" "GBP_AUD" "GBP_CAD"
    "AUD_JPY" "AUD_NZD" "AUD_CAD"
    "NZD_JPY" "NZD_CAD"
    "CAD_JPY" "CAD_CHF" "CHF_JPY"
    # Commodities
    "WTICO_USD" "BCO_USD" "NATGAS_USD" "XCU_USD"
    "CORN_USD" "SOYBN_USD" "WHEAT_USD" "SUGAR_USD"
    # Metals
    "XAU_USD" "XAG_USD" "XPT_USD" "XPD_USD"
    # Indices
    "SPX500_USD" "NAS100_USD" "US30_USD" "UK100_GBP"
    "DE30_EUR" "JP225_USD" "AU200_AUD" "EU50_EUR"
)

# Backfill All instruments with 5 years of data on H1 candles
# DAYS=1825
# GRANULARITY="H1"

# echo "=== Backfilling ${#INSTRUMENTS[@]} instruments (${DAYS} days of ${GRANULARITY}) ==="

# for instrument in "${INSTRUMENTS[@]}"; do
#     echo ""
#     echo "--- ${instrument} ---"
#     curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=${GRANULARITY}&days=${DAYS}" | python3 -m json.tool
# done

DAYS=365
GRANULARITY="M15"

echo "=== Backfilling ${#INSTRUMENTS[@]} instruments (${DAYS} days of ${GRANULARITY}) ==="

for instrument in CHF_JPY AUD_CAD XPT_USD BCO_USD UK100_GBP; do
    echo ""
    echo "--- ${instrument} ---"
    curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=${GRANULARITY}&days=${DAYS}" | python3 -m json.tool
done

echo ""
echo "=== Backfill complete ==="
echo ""
echo "=== Candle counts ==="
docker exec -it amplyiq-postgres psql -U postgres -d auro -c "
SELECT instrument, granularity, COUNT(*) as candles, MIN(timestamp)::date as from_date, MAX(timestamp)::date as to_date
FROM candles
WHERE granularity = '${GRANULARITY}'
GROUP BY instrument, granularity
ORDER BY instrument;
"
