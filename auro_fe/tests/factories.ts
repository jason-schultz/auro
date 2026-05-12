import type { BacktestRun } from "../src/types/backtest";
import type { BacktestStats, LiveStats, LiveStrategy } from "../src/types/live";

export function makeBacktestRun(overrides: Partial<BacktestRun> = {}): BacktestRun {
    return {
        id: "1",
        strategy_name: "test",
        strategy_type: "trend_following",
        instrument: "EUR_USD",
        granularity: "H1",
        parameters: {},
        total_return: 0,
        win_rate: 0,
        sharpe_ratio: 0,
        max_drawdown: 0,
        num_trades: 0,
        avg_win: 0,
        avg_loss: 0,
        status: "valid",
        reason_flagged: null,
        execution_duration_ms: 0,
        ...overrides,
    };
}

export function makeBacktestStats(overrides: Partial<BacktestStats> = {}): BacktestStats {
    return {
        total_return: 0.12,
        win_rate: 0.55,
        sharpe_ratio: 1.1,
        max_drawdown: 0.08,
        num_trades: 30,
        avg_win: 0.8,
        avg_loss: 0.5,
        ...overrides,
    };
}

export function makeLiveStats(overrides: Partial<LiveStats> = {}): LiveStats {
    return {
        num_trades: 10,
        wins: 6,
        losses: 4,
        win_rate: 0.6,
        total_return: 0.04,
        avg_win: 0.75,
        avg_loss: 0.45,
        ...overrides,
    };
}

export function makeLiveStrategy(overrides: Partial<LiveStrategy> = {}): LiveStrategy {
    return {
        id: "s1",
        strategy_type: "trend_following",
        instrument: "EUR_USD",
        granularity: "H1",
        parameters: {
            fast_period: 20,
            slow_period: 50,
            stop_loss: 0.01,
            take_profit: 0.02,
        },
        enabled: true,
        max_position_size: "1000",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        backtest_run_id: null,
        source: "pipeline",
        pipeline_score: null,
        backtest_stats: makeBacktestStats(),
        oos_stats: null,
        live_stats: makeLiveStats(),
        ...overrides,
    };
}
