// Per-bar indicator series for the strategy-editor chart overlays.
//
// These mirror the Rust math in auro_be/src/engine/indicators.rs — frozen
// conventions: EMA seeded with the SMA of the first `period` bars, Wilder
// RSI with flat-series → 50, population stdev for z-bands, Donchian channel
// over the `period` bars BEFORE the current bar. The overlays are
// visualization only (signals come from Rust), but they must agree with what
// the backtest computes or the chart lies.

export interface OhlcBar {
    time: number;
    open: number;
    high: number;
    low: number;
    close: number;
}

export interface LinePoint {
    time: number;
    value: number;
}

export function smaSeries(bars: OhlcBar[], period: number): LinePoint[] {
    if (period < 1 || bars.length < period) return [];

    const out: LinePoint[] = [];
    let sum = 0;
    for (let i = 0; i < bars.length; i++) {
        sum += bars[i].close;
        if (i >= period) sum -= bars[i - period].close;
        if (i >= period - 1) out.push({ time: bars[i].time, value: sum / period });
    }
    return out;
}

export function emaSeries(bars: OhlcBar[], period: number): LinePoint[] {
    return emaOfValues(
        bars.map((b) => b.close),
        bars.map((b) => b.time),
        period,
    );
}

function emaOfValues(values: number[], times: number[], period: number): LinePoint[] {
    if (period < 1 || values.length < period) return [];

    const k = 2 / (period + 1);
    let ema = values.slice(0, period).reduce((a, b) => a + b, 0) / period;
    const out: LinePoint[] = [{ time: times[period - 1], value: ema }];

    for (let i = period; i < values.length; i++) {
        ema = values[i] * k + ema * (1 - k);
        out.push({ time: times[i], value: ema });
    }
    return out;
}

export function maSeries(bars: OhlcBar[], period: number, maType: string): LinePoint[] {
    return maType === "ema" ? emaSeries(bars, period) : smaSeries(bars, period);
}

/** Wilder RSI. Flat window → 50, only-gains → 100 (matches Rust). */
export function rsiSeries(bars: OhlcBar[], period: number): LinePoint[] {
    if (period < 1 || bars.length < period + 1) return [];

    const gains: number[] = [];
    const losses: number[] = [];
    for (let i = 1; i < bars.length; i++) {
        const delta = bars[i].close - bars[i - 1].close;
        gains.push(delta >= 0 ? delta : 0);
        losses.push(delta < 0 ? -delta : 0);
    }

    let avgGain = gains.slice(0, period).reduce((a, b) => a + b, 0) / period;
    let avgLoss = losses.slice(0, period).reduce((a, b) => a + b, 0) / period;

    const out: LinePoint[] = [];
    const push = (barIdx: number) => {
        let value: number;
        if (avgGain === 0 && avgLoss === 0) value = 50;
        else if (avgLoss === 0) value = 100;
        else value = 100 - 100 / (1 + avgGain / avgLoss);
        out.push({ time: bars[barIdx].time, value });
    };

    push(period);
    for (let i = period; i < gains.length; i++) {
        avgGain = (avgGain * (period - 1) + gains[i]) / period;
        avgLoss = (avgLoss * (period - 1) + losses[i]) / period;
        push(i + 1);
    }
    return out;
}

export interface MacdSeries {
    macd: LinePoint[];
    signal: LinePoint[];
    histogram: LinePoint[];
}

export function macdSeries(
    bars: OhlcBar[],
    fast: number,
    slow: number,
    signal: number,
): MacdSeries {
    const empty = { macd: [], signal: [], histogram: [] };
    if (fast < 1 || slow < 1 || signal < 1 || fast >= slow) return empty;
    if (bars.length < slow + signal) return empty;

    const fastLine = emaSeries(bars, fast);
    const slowLine = emaSeries(bars, slow);

    // Both EMA series are time-aligned to bars; the MACD line starts where
    // the slow EMA starts.
    const offset = slowLine.length > 0 ? fastLine.length - slowLine.length : 0;
    const macd: LinePoint[] = slowLine.map((point, i) => ({
        time: point.time,
        value: fastLine[i + offset].value - point.value,
    }));

    const signalLine = emaOfValues(
        macd.map((p) => p.value),
        macd.map((p) => p.time),
        signal,
    );

    const sigOffset = macd.length - signalLine.length;
    const histogram: LinePoint[] = signalLine.map((point, i) => ({
        time: point.time,
        value: macd[i + sigOffset].value - point.value,
    }));

    return { macd, signal: signalLine, histogram };
}

export interface ChannelSeries {
    upper: LinePoint[];
    lower: LinePoint[];
}

/** Donchian channel at bar i spans the `period` bars BEFORE i (matches Rust). */
export function donchianSeries(bars: OhlcBar[], period: number): ChannelSeries {
    if (period < 1 || bars.length < period + 1) return { upper: [], lower: [] };

    const upper: LinePoint[] = [];
    const lower: LinePoint[] = [];
    for (let i = period; i < bars.length; i++) {
        const window = bars.slice(i - period, i);
        upper.push({
            time: bars[i].time,
            value: Math.max(...window.map((b) => b.high)),
        });
        lower.push({
            time: bars[i].time,
            value: Math.min(...window.map((b) => b.low)),
        });
    }
    return { upper, lower };
}

export interface BandSeries {
    middle: LinePoint[];
    upper: LinePoint[];
    lower: LinePoint[];
}

/** SMA ± z × population stdev — the MR entry envelope. */
export function zBandSeries(bars: OhlcBar[], period: number, z: number): BandSeries {
    if (period < 1 || bars.length < period) return { middle: [], upper: [], lower: [] };

    const middle: LinePoint[] = [];
    const upper: LinePoint[] = [];
    const lower: LinePoint[] = [];

    for (let i = period - 1; i < bars.length; i++) {
        const window = bars.slice(i - period + 1, i + 1).map((b) => b.close);
        const mean = window.reduce((a, b) => a + b, 0) / period;
        const variance = window.reduce((a, b) => a + (b - mean) ** 2, 0) / period;
        const stdev = Math.sqrt(variance);

        const time = bars[i].time;
        middle.push({ time, value: mean });
        upper.push({ time, value: mean + z * stdev });
        lower.push({ time, value: mean - z * stdev });
    }
    return { middle, upper, lower };
}
