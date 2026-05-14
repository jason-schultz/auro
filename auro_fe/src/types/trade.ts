import type { StrategyParameters } from "@/types/strategy";

export interface TradeData {
    id: string;
    oanda_trade_id: string | null;
    instrument: string;
    direction: string;
    units: string;
    entry_price: number | null;
    exit_price: number | null;
    entry_time: string;
    exit_time: string | null;
    pnl_percent: number | null;
    entry_reason: string | null;
    exit_reason: string | null;
    status: string;
}

export interface StrategyData {
    id: string;
    strategy_type: string | null;
    parameters: StrategyParameters | null;
    granularity: string | null;
    enabled: boolean | null;
    max_position_size: string | null;
    backtest_run_id: string | null;
}

export interface BacktestData {
    id: string;
    strategy_name: string | null;
    total_return: number | null;
    win_rate: number | null;
    sharpe_ratio: number | null;
    max_drawdown: number | null;
    num_trades: number | null;
    avg_win: number | null;
    avg_loss: number | null;
}

export interface LiveAggregateData {
    num_trades: number;
    wins: number;
    losses: number;
    win_rate: number;
    total_return: number;
    avg_win: number;
    avg_loss: number;
}

export interface TradeDetailResponse {
    trade: TradeData;
    strategy: StrategyData | null;
    backtest: BacktestData | null;
    live_aggregate: LiveAggregateData | null;
}

export interface JournalTrade {
    id: string;
    oanda_trade_id: string | null;
    instrument: string;
    direction: string;
    units: string;
    entry_price: number | null;
    exit_price: number | null;
    entry_time: string;
    exit_time: string | null;
    pnl_percent: number | null;
    entry_reason: string | null;
    exit_reason: string | null;
    status: string;
    strategy_type: string | null;
    strategy_granularity: string | null;
    strategy_parameters: Record<string, unknown> | null;
    indicators_at_entry: Record<string, unknown> | null;
    regime_at_entry: string | null;
    mae_pct: number | null;
    mfe_pct: number | null;
    stop_loss_state_at_close: string | null;
}

export interface JournalResponse {
    trades: JournalTrade[];
    count: number;
}
