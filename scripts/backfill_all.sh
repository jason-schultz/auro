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

echo ""
echo "=== Backfilling D candles (8 years) ==="
for instrument in "${INSTRUMENTS[@]}"; do
    echo "--- ${instrument} D ---"
    curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=D&days=2920" > /dev/null
done

# echo "=== Backfilling H1 candles (8 years) ==="
# for instrument in "${INSTRUMENTS[@]}"; do
#     echo "--- ${instrument} H1 ---"
#     curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=H1&days=2920" > /dev/null
# done

# echo "=== Backfilling H4 candles (8 years) ==="
# for instrument in "${INSTRUMENTS[@]}"; do
#     echo "--- ${instrument} H4 ---"
#     curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=H4&days=2920" > /dev/null
# done

# echo ""
# echo "=== Backfilling M15 candles (2 years) ==="
# for instrument in "${INSTRUMENTS[@]}"; do
#     echo "--- ${instrument} M15 ---"
#     curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=M15&days=730" > /dev/null
# done

# echo ""
# echo "=== Backfilling M5 candles (2 years) ==="
# for instrument in "${INSTRUMENTS[@]}"; do
#     echo "--- ${instrument} M5 ---"
#     curl -s -X POST "http://localhost:3000/api/backtest/backfill?instrument=${instrument}&granularity=M5&days=730" > /dev/null
# done

echo ""
echo "=== Backfill complete ==="
echo ""
echo "=== Candle counts ==="
docker exec -it amplyiq-postgres psql -U postgres -d auro -c "
SELECT granularity, COUNT(*) as total_candles, COUNT(DISTINCT instrument) as instruments
FROM candles
WHERE granularity IN ('D', 'H1', 'H4', 'M15', 'M5', 'M1')
GROUP BY granularity
ORDER BY granularity;
"