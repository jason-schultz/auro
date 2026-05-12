export interface TrendFollowingParams {
    fast_period?: number;
    slow_period?: number;
    stop_loss?: number;
    take_profit?: number | null;
}

export interface MeanReversionParams {
    ma_period?: number;
    entry_threshold?: number;
    exit_threshold?: number;
    stop_loss?: number;
}

export type StrategyParameters = TrendFollowingParams & MeanReversionParams;
