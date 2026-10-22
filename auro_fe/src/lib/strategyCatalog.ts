// Catalog of composite-strategy building blocks, mirroring the Rust schema in
// auro_be/src/engine/strategy.rs. Component types, their params (with the same
// serde field names), and the bool output ports each component exposes.
// Keep in sync when a new Signaler lands in Rust.

export interface ParamSpec {
    key: string;
    label: string;
    kind: "int" | "float" | "choice";
    default: number | string;
    /** Allowed values when kind is "choice". */
    options?: readonly string[];
    min?: number;
    step?: number;
    hint?: string;
}

export interface ComponentSpec {
    type: string;
    label: string;
    description: string;
    params: ParamSpec[];
    ports: string[];
}

export const MA_TYPES = ["sma", "ema"] as const;
/** Opus macro calendars that keep an EventWindow's release times current. */
export const MACRO_CALENDARS = ["fomc", "cpi", "nfp"] as const;

export const COMPONENT_CATALOG: ComponentSpec[] = [
    {
        type: "TrendFollowing",
        label: "MA Cross (Trend Following)",
        description: "Fast/slow moving-average crossover.",
        params: [
            { key: "fast_period", label: "Fast period", kind: "int", default: 50, min: 2 },
            { key: "slow_period", label: "Slow period", kind: "int", default: 200, min: 3 },
            { key: "ma_type", label: "MA type", kind: "choice", options: MA_TYPES, default: "sma" },
        ],
        ports: ["bullish_cross", "bearish_cross", "bullish", "bearish"],
    },
    {
        type: "MeanReversion",
        label: "Z-Score Mean Reversion",
        description: "Z-score extension from MA with RSI confirmation.",
        params: [
            { key: "ma_period", label: "MA period", kind: "int", default: 20, min: 5 },
            { key: "rsi_period", label: "RSI period", kind: "int", default: 14, min: 2 },
            { key: "entry_z_threshold", label: "Entry Z threshold", kind: "float", default: 1.5, step: 0.1 },
            { key: "rsi_oversold", label: "RSI oversold", kind: "float", default: 30, step: 1 },
            { key: "rsi_overbought", label: "RSI overbought", kind: "float", default: 70, step: 1 },
            { key: "stop_z_threshold", label: "Stop Z threshold", kind: "float", default: 3.5, step: 0.1, hint: "Z-extension stop in the adverse direction" },
        ],
        ports: ["long", "short", "exit_long", "exit_short"],
    },
    {
        type: "Macd",
        label: "MACD",
        description: "MACD line vs signal line crosses and posture.",
        params: [
            { key: "fast_period", label: "Fast period", kind: "int", default: 12, min: 2 },
            { key: "slow_period", label: "Slow period", kind: "int", default: 26, min: 3 },
            { key: "signal_period", label: "Signal period", kind: "int", default: 9, min: 2 },
        ],
        ports: ["bullish_cross", "bearish_cross", "bullish", "bearish"],
    },
    {
        type: "Donchian",
        label: "Donchian Breakout",
        description: "N-bar high/low channel breakout with exit channel.",
        params: [
            { key: "entry_period", label: "Entry period", kind: "int", default: 20, min: 2 },
            { key: "exit_period", label: "Exit period", kind: "int", default: 10, min: 2 },
        ],
        ports: ["breakout_long", "breakout_short", "exit_long", "exit_short"],
    },
    {
        type: "MaFilter",
        label: "MA Filter",
        description: "Price above/below a single MA — use as a trend gate.",
        params: [
            { key: "period", label: "Period", kind: "int", default: 100, min: 2 },
            { key: "ma_type", label: "MA type", kind: "choice", options: MA_TYPES, default: "sma" },
        ],
        ports: ["above", "below"],
    },
    {
        type: "RsiReversion",
        label: "RSI Reversion",
        description: "RSI oversold/overbought entry with midline exits.",
        params: [
            { key: "rsi_period", label: "RSI period", kind: "int", default: 2, min: 2 },
            { key: "oversold", label: "Oversold", kind: "float", default: 10, step: 1 },
            { key: "overbought", label: "Overbought", kind: "float", default: 90, step: 1 },
        ],
        ports: ["long", "short", "exit_long", "exit_short"],
    },
    {
        type: "NoiseArea",
        label: "Noise-Area Intraday Momentum",
        description:
            "Zarattini et al. 2024: breakout of the time-of-day noise band, VWAP trail, flat at the NYSE close. M5 index CFDs.",
        params: [
            { key: "lookback_sessions", label: "Lookback sessions", kind: "int", default: 14, min: 1 },
            { key: "band_mult", label: "Band multiplier", kind: "float", default: 1.0, step: 0.1 },
        ],
        ports: ["long", "short", "exit_long", "exit_short", "session_close"],
    },
    {
        type: "Momentum",
        label: "Momentum (time-series)",
        description: "Sign of the return over the lookback (e.g. 252 daily bars = 12-month trend).",
        params: [{ key: "lookback", label: "Lookback (bars)", kind: "int", default: 252, min: 1 }],
        ports: ["up", "down"],
    },
    {
        type: "EventWindow",
        label: "Macro Event Window",
        description:
            "In-window around scheduled releases. Opus fills release times daily from the chosen calendar.",
        params: [
            { key: "calendar", label: "Calendar", kind: "choice", options: MACRO_CALENDARS, default: "fomc" },
            { key: "start_offset_minutes", label: "Start (min from release)", kind: "int", default: -1440, hint: "negative = before release" },
            { key: "end_offset_minutes", label: "End (min from release)", kind: "int", default: 0 },
        ],
        ports: ["in_window", "out_of_window"],
    },
];

export function componentSpec(type: string): ComponentSpec | undefined {
    return COMPONENT_CATALOG.find((c) => c.type === type);
}

export function defaultParams(spec: ComponentSpec): Record<string, number | string> {
    return Object.fromEntries(spec.params.map((p) => [p.key, p.default]));
}

// PortRef mirrors Rust's untagged enum: a plain string ("tf.bullish_cross")
// or {and: [...]}, {or: [...]}, {not: ...}.
export type PortRef =
    | string
    | { and: PortRef[] }
    | { or: PortRef[] }
    | { not: PortRef };

export interface StopConfig {
    type: "FixedPct" | "AtrMultiple" | "FromComponent";
    params: Record<string, number | string>;
}

export interface CompositeStrategyConfig {
    strategy_id: null;
    strategy_name: string | null;
    version: string;
    instrument: string;
    granularity: string;
    components: Record<string, { type: string; params: Record<string, number | string> }>;
    // A disabled side is simply omitted — the engine treats a missing side
    // as "never fires."
    entry: { long?: PortRef; short?: PortRef };
    exit: { long?: PortRef; short?: PortRef };
    stop: StopConfig;
    sizing: { type: "RiskPct"; params: { pct: number; max_notional_pct?: number } };
    max_hold_bars: number | null;
}
