export const METRIC_EXPLAINERS = {
    winRate:
        "Of all closed trades, the share that ended in profit. 50% with bigger wins than losses is fine; 70% with tiny wins and huge losses is not.",
    avgWinAvgLoss:
        "Average $ of profitable vs losing trades. The ratio (avg_win / avg_loss) matters more than win rate alone - it's your edge per trade.",
    totalPnl:
        "Sum of realized profit/loss across all closed trades, in account currency.",
    mae:
        "Worst the trade looked before it closed. If MAE is consistently close to your stop, your stops are well-placed; if MAE is small but you still lost, your stop may be too tight.",
    mfe:
        "Best the trade looked before it closed. If MFE is much bigger than your realized win, you're leaving profit on the table - TP is too close or trailing is too aggressive.",
    regimeAtEntry:
        "What the market was doing (trending / ranging / volatile) when the trade fired. Lets you ask 'do I only win in trends?'",
    stopLossStateAtClose:
        "Where the stop was when the trade closed (initial / breakeven / trailing). Tells you whether your trade-management rules actually moved the stop before the exit.",
    pnlPercent:
        "Return on this trade as a percent of entry price. Useful for comparing trades across instruments.",
    entry:
        "The price and timestamp when the trade opened.",
    exit:
        "The price and timestamp when the trade closed.",
    duration:
        "How long the trade was open from entry to exit.",
    granularity:
        "The candle timeframe this strategy trades on (for example H1 or H4).",
    maxPosition:
        "Configured order size used when this strategy opens a trade.",
    tradeCount:
        "How many closed trades are included in this summary.",
    expectancy:
        "Average expected return per trade from win rate and average win/loss. Positive means edge, negative means drift.",
    sharpe:
        "Risk-adjusted return. Higher is better because it means more return per unit of variability.",
    maxDrawdown:
        "Largest peak-to-trough loss during the test period.",
    tradeVsAvg:
        "How this trade compares to the strategy's historical average win or loss size.",
};

export const JOURNAL_METRIC_EXPLAINERS: Record<string, string> = {
    entry_price: METRIC_EXPLAINERS.entry,
    exit_price: METRIC_EXPLAINERS.exit,
    pnl_percent: METRIC_EXPLAINERS.pnlPercent,
    duration: METRIC_EXPLAINERS.duration,
    mae_pct: METRIC_EXPLAINERS.mae,
    mfe_pct: METRIC_EXPLAINERS.mfe,
    regime_at_entry: METRIC_EXPLAINERS.regimeAtEntry,
    stop_loss_state_at_close: METRIC_EXPLAINERS.stopLossStateAtClose,
};

export const TRADE_DETAIL_LABEL_EXPLAINERS: Record<string, string> = {
    Entry: METRIC_EXPLAINERS.entry,
    Exit: METRIC_EXPLAINERS.exit,
    "P&L": METRIC_EXPLAINERS.pnlPercent,
    Duration: METRIC_EXPLAINERS.duration,
    Granularity: METRIC_EXPLAINERS.granularity,
    "Max Position": METRIC_EXPLAINERS.maxPosition,
    "# Trades": METRIC_EXPLAINERS.tradeCount,
    "Live Win Rate": METRIC_EXPLAINERS.winRate,
    "Win Rate": METRIC_EXPLAINERS.winRate,
    "Live Total Return": METRIC_EXPLAINERS.totalPnl,
    "Total Return": METRIC_EXPLAINERS.totalPnl,
    "Live Expectancy": METRIC_EXPLAINERS.expectancy,
    "Live Avg Win": METRIC_EXPLAINERS.avgWinAvgLoss,
    "Live Avg Loss": METRIC_EXPLAINERS.avgWinAvgLoss,
    "Avg Win": METRIC_EXPLAINERS.avgWinAvgLoss,
    "Avg Loss": METRIC_EXPLAINERS.avgWinAvgLoss,
    "Sharpe Ratio": METRIC_EXPLAINERS.sharpe,
    "Max Drawdown": METRIC_EXPLAINERS.maxDrawdown,
    "Trade vs Avg": METRIC_EXPLAINERS.avgWinAvgLoss,
};
