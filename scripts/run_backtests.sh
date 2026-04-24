#!/bin/bash
# run_backtests.sh — Run grid search across instruments
#
# Usage:
#   ./run_backtests.sh [options]
#
# Options:
#   -s, --strategy   Strategy to run: mean_reversion, trend_following, or both (default: both)
#   -p, --parallel   Number of parallel jobs (default: 1)
#   -c, --clear      Clear old backtest results before running
#   -i, --instrument Run a single instrument only (e.g. EUR_USD)
#   -h, --help       Show this help
#
# Examples:
#   ./run_backtests.sh                                  # Both strategies, sequential
#   ./run_backtests.sh -s mean_reversion -p 4           # Mean reversion only, 4 parallel
#   ./run_backtests.sh -s trend_following -p 2 -c       # Trend following, 2 parallel, clear first
#   ./run_backtests.sh -i EUR_USD -s both               # Single instrument, both strategies
#   ./run_backtests.sh -p 4 -c                          # Everything, 4 parallel, fresh start

set -e

BASE_URL="http://127.0.0.1:3000/api"
TIMEFRAME="M15"
STRATEGY="both"
PARALLEL=1
CLEAR=false
SINGLE_INSTRUMENT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--strategy)
            STRATEGY="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL="$2"
            shift 2
            ;;
        -c|--clear)
            CLEAR=true
            shift
            ;;
        -i|--instrument)
            SINGLE_INSTRUMENT="$2"
            shift 2
            ;;
        -h|--help)
            head -17 "$0" | tail -15
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with -h for help"
            exit 1
            ;;
    esac
done

# Validate strategy
if [[ "$STRATEGY" != "mean_reversion" && "$STRATEGY" != "trend_following" && "$STRATEGY" != "both" ]]; then
    echo "Invalid strategy: $STRATEGY"
    echo "Must be: mean_reversion, trend_following, or both"
    exit 1
fi

# Prevent macOS from sleeping
if command -v caffeinate &> /dev/null; then
    caffeinate -i -w $$ &
fi

# Instruments list
if [[ -n "$SINGLE_INSTRUMENT" ]]; then
    INSTRUMENTS="$SINGLE_INSTRUMENT"
else
    # Hardcoded from the candles table — update if you add more instruments
    INSTRUMENTS="AU200_AUD AUD_CAD AUD_JPY AUD_NZD AUD_USD BCO_USD CAD_CHF CAD_JPY CHF_JPY CORN_USD DE30_EUR EU50_EUR EUR_AUD EUR_CAD EUR_CHF EUR_GBP EUR_JPY EUR_USD GBP_AUD GBP_CAD GBP_JPY GBP_USD JP225_USD NAS100_USD NATGAS_USD NZD_CAD NZD_JPY NZD_USD SOYBN_USD SPX500_USD SUGAR_USD UK100_GBP US30_USD USD_CAD USD_JPY WHEAT_USD WTICO_USD XAG_USD XAU_USD XCU_USD XPD_USD XPT_USD"
fi

INSTRUMENT_COUNT=$(echo "$INSTRUMENTS" | wc -w | tr -d ' ')

# Build strategy list
if [[ "$STRATEGY" == "both" ]]; then
    STRATEGIES="mean_reversion trend_following"
    STRAT_COUNT=2
else
    STRATEGIES="$STRATEGY"
    STRAT_COUNT=1
fi

TOTAL_JOBS=$((INSTRUMENT_COUNT * STRAT_COUNT))

echo "=============================================="
echo "  Auro Grid Search"
echo "=============================================="
echo "  Strategies:  $STRATEGY"
echo "  Instruments: $INSTRUMENT_COUNT"
echo "  Total jobs:  $TOTAL_JOBS"
echo "  Parallel:    $PARALLEL"
echo "  Timeframe:   $TIMEFRAME"
echo "  Clear first: $CLEAR"
echo "=============================================="

# Clear old results if requested — uses the API to avoid needing psql
if [[ "$CLEAR" == "true" ]]; then
    echo ""
    echo "Clearing old backtest results..."

    # Delete trades first (FK constraint), then runs
    # Using a simple endpoint — if you don't have one yet, add it or run manually:
    #   docker exec amplyiq-postgres psql -U <user> -d <db> -c "DELETE FROM backtest_trades; DELETE FROM backtest_runs;"
    CLEAR_RESULT=$(curl -s -X DELETE "$BASE_URL/backtest/results" 2>&1)
    if echo "$CLEAR_RESULT" | grep -q "error\|404\|405"; then
        echo "  API delete not available. Clear manually:"
        echo "    docker exec amplyiq-postgres psql -U postgres -d auro -c 'DELETE FROM backtest_trades; DELETE FROM backtest_runs;'"
        echo ""
        read -p "  Continue without clearing? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 0
        fi
    else
        echo "  Cleared."
    fi
    echo ""
fi

# Run function
run_one() {
    local instrument=$1
    local strategy=$2
    local index=$3
    local total=$4

    local start_time=$(date +%s)

    local result=$(curl -s -X POST "$BASE_URL/backtest/run?instrument=$instrument&timeframe=$TIMEFRAME&strategy=$strategy" 2>&1)

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Parse results from JSON response
    local valid=$(echo "$result" | grep -o '"valid":[0-9]*' | head -1 | cut -d: -f2)
    local verify=$(echo "$result" | grep -o '"verify":[0-9]*' | head -1 | cut -d: -f2)
    local failed=$(echo "$result" | grep -o '"failed":[0-9]*' | head -1 | cut -d: -f2)
    local grid_time=$(echo "$result" | grep -o '"grid_seconds":[0-9.]*' | head -1 | cut -d: -f2)
    local store_time=$(echo "$result" | grep -o '"store_seconds":[0-9.]*' | head -1 | cut -d: -f2)
    local error=$(echo "$result" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$error" ]]; then
        echo "[$index/$total] SKIP $strategy on $instrument — $error"
    else
        local strat_short="MR"
        [[ "$strategy" == "trend_following" ]] && strat_short="TF"

        printf "[%d/%d] %-6s %-12s — valid:%-3s verify:%-3s failed:%-4s | grid:%ss store:%ss total:%ss\n" \
            "$index" "$total" "$strat_short" "$instrument" \
            "${valid:-0}" "${verify:-0}" "${failed:-0}" \
            "${grid_time:-?}" "${store_time:-?}" "$elapsed"
    fi
}

export -f run_one
export BASE_URL TIMEFRAME

# Build job list
JOBS_FILE=$(mktemp)
INDEX=0

for strategy in $STRATEGIES; do
    for instrument in $INSTRUMENTS; do
        INDEX=$((INDEX + 1))
        echo "$instrument $strategy $INDEX $TOTAL_JOBS" >> "$JOBS_FILE"
    done
done

START_ALL=$(date +%s)

JOBS=()
while IFS=' ' read -r line; do
    JOBS+=("$line")
done < "$JOBS_FILE"

for ((i=0; i<${#JOBS[@]}; i+=PARALLEL)); do
    for ((j=i; j<i+PARALLEL && j<${#JOBS[@]}; j++)); do
        read -r instrument strategy index total <<< "${JOBS[$j]}"
        (
            start_time=$(date +%s)
            result=$(curl -s -X POST "$BASE_URL/backtest/run?instrument=$instrument&timeframe=$TIMEFRAME&strategy=$strategy" 2>&1)
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))

            valid=$(echo "$result" | grep -o '"valid":[0-9]*' | head -1 | cut -d: -f2)
            verify=$(echo "$result" | grep -o '"verify":[0-9]*' | head -1 | cut -d: -f2)
            failed=$(echo "$result" | grep -o '"failed":[0-9]*' | head -1 | cut -d: -f2)
            error=$(echo "$result" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)

            strat_short="MR"
            [[ "$strategy" == "trend_following" ]] && strat_short="TF"

            if [[ -n "$error" ]]; then
                echo "[$index/$total] SKIP $strat_short $instrument — $error"
            else
                printf "[%d/%d] %-4s %-12s — valid:%-3s verify:%-3s failed:%-4s (%ss)\n" \
                    "$index" "$total" "$strat_short" "$instrument" \
                    "${valid:-0}" "${verify:-0}" "${failed:-0}" "$elapsed"
            fi
        ) &
    done
    wait
done

END_ALL=$(date +%s)
TOTAL_ELAPSED=$((END_ALL - START_ALL))

rm -f "$JOBS_FILE"

echo ""
echo "=============================================="
echo "  Complete"
echo "=============================================="
echo "  Total time: ${TOTAL_ELAPSED}s ($((TOTAL_ELAPSED / 60))m $((TOTAL_ELAPSED % 60))s)"
if [[ "$TOTAL_JOBS" -gt 0 ]]; then
    echo "  Avg per job: $((TOTAL_ELAPSED / TOTAL_JOBS))s"
fi
echo "=============================================="
