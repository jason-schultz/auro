import { formatPercent } from "./format";

export function badgePillClasses(params: {
    size: "xs" | "2xs";
    rounded: "default" | "full";
    extraClass?: string;
}): string {
    const sizeClass = params.size === "2xs"
        ? "text-[9px] px-1 py-0.5"
        : "text-[10px] px-1.5 py-0.5";

    const roundedClass = params.rounded === "full" ? "rounded-full" : "rounded";

    return [
        "inline-flex items-center font-medium",
        sizeClass,
        roundedClass,
        params.extraClass ?? "",
    ]
        .filter(Boolean)
        .join(" ");
}

export interface StatGridItem {
    label: string;
    value: string;
    explainer?: string;
    valueClass?: string;
    meta?: string;
    metaClass?: string;
}

export interface TableColumn {
    key: string;
    label: string;
    sortable: boolean;
}


export const PIPELINE_COLUMNS = [
    { key: "instrument", label: "Instrument", sortable: true },
    { key: "strategy_type", label: "Strategy", sortable: true },
    { key: "granularity", label: "Gran", sortable: true },
    { key: "variant", label: "Variant", sortable: true },
    { key: "generation", label: "Gen", sortable: true },
    { key: "stage", label: "Stage", sortable: true },
    { key: "status", label: "Status", sortable: true },
    { key: "sharpe", label: "Sharpe", sortable: true },
    { key: "trades", label: "Trades", sortable: true },
    { key: "drawdown", label: "Drawdown", sortable: true },
    { key: "score", label: "Score", sortable: true },
    { key: "failure_reason", label: "Failure", sortable: true },
] satisfies TableColumn[];

export const STRATEGIES_COLUMNS = [
    { key: "instrument", label: "Pair", sortable: true },
    { key: "strategy_type", label: "Type", sortable: true },
    { key: "granularity", label: "TF", sortable: false },
    { key: "params", label: "Parameters", sortable: false },
    { key: "total_return", label: "BT Return", sortable: true },
    { key: "win_rate", label: "BT Win%", sortable: true },
    { key: "sharpe_ratio", label: "IS Sharpe", sortable: true },
    { key: "oos_sharpe", label: "OOS Sharpe", sortable: true },
    { key: "kfold", label: "K-Fold", sortable: true },
    { key: "max_drawdown", label: "DD", sortable: true },
    { key: "num_trades", label: "BT #", sortable: true },
    { key: "live_num_trades", label: "Live #", sortable: true },
    { key: "live_win_rate", label: "Live Win%", sortable: true },
    { key: "edge", label: "Edge", sortable: false },
    { key: "enabled", label: "Live", sortable: true },
] satisfies TableColumn[];

export const JOURNAL_COLUMNS = [
    { key: "instrument", label: "Instrument", sortable: true },
    { key: "strategy_type", label: "Strategy", sortable: true },
    { key: "direction", label: "Dir", sortable: false },
    { key: "entry_price", label: "Entry", sortable: true },
    { key: "exit_price", label: "Exit", sortable: false },
    { key: "pnl_percent", label: "PnL %", sortable: true },
    { key: "duration", label: "Duration", sortable: false },
    { key: "mae_pct", label: "MAE %", sortable: true },
    { key: "mfe_pct", label: "MFE %", sortable: true },
    { key: "regime_at_entry", label: "Regime", sortable: false },
    { key: "exit_reason", label: "Exit Reason", sortable: false },
    { key: "stop_loss_state_at_close", label: "SL State", sortable: false },
] satisfies TableColumn[];

export const TABLE_WIDTH_TOKENS = {
    pipeline: {
        instrument: "w-[8.5rem] min-w-[8.5rem]",
        strategy_type: "w-[7.5rem] min-w-[7.5rem]",
        granularity: "w-[4.5rem] min-w-[4.5rem]",
        variant: "w-[7rem] min-w-[7rem]",
        generation: "w-[5rem] min-w-[5rem]",
        stage: "w-[6rem] min-w-[6rem]",
        status: "w-[5.5rem] min-w-[5.5rem]",
        sharpe: "w-[4.5rem] min-w-[4.5rem]",
        trades: "w-[4rem] min-w-[4rem]",
        drawdown: "w-[5.25rem] min-w-[5.25rem]",
        score: "w-[4.5rem] min-w-[4.5rem]",
        failure_reason: "w-[13rem] min-w-[13rem]",
    },
    strategies: {
        instrument: "w-[8.5rem] min-w-[8.5rem]",
        strategy_type: "w-[7.5rem] min-w-[7.5rem]",
        granularity: "w-[4.5rem] min-w-[4.5rem]",
        params: "w-[16rem] min-w-[16rem]",
        total_return: "w-[5.75rem] min-w-[5.75rem]",
        win_rate: "w-[5.5rem] min-w-[5.5rem]",
        sharpe_ratio: "w-[5rem] min-w-[5rem]",
        oos_sharpe: "w-[6rem] min-w-[6rem]",
        max_drawdown: "w-[5rem] min-w-[5rem]",
        num_trades: "w-[4rem] min-w-[4rem]",
        live_num_trades: "w-[4.5rem] min-w-[4.5rem]",
        live_win_rate: "w-[6rem] min-w-[6rem]",
        edge: "w-[5rem] min-w-[5rem]",
        enabled: "w-[4rem] min-w-[4rem]",
        actions: "w-[2.5rem] min-w-[2.5rem]",
    },
} as const;

const METRIC_KEYS = new Set([
    "ma_period",
    "entry_threshold",
    "exit_threshold",
    "fast_period",
    "slow_period",
    "take_profit",
    "stop_loss",
    "num_trades",
    "total_return",
    "win_rate",
    "sharpe_ratio",
    "oos_sharpe",
    "max_drawdown",
    "generation",
    "sharpe",
    "trades",
    "drawdown",
    "score",
    "live_num_trades",
    "live_win_rate",
]);

export function tableWidthClass(
    table: keyof typeof TABLE_WIDTH_TOKENS,
    key: string,
): string {
    const widths = TABLE_WIDTH_TOKENS[table] as Record<string, string>;
    return widths[key] ?? "w-[7rem] min-w-[7rem]";
}

export function ariaSortForColumn(params: {
    sortable: boolean;
    columnKey: string;
    sortKey: string;
    sortDir: "asc" | "desc";
}): "none" | "ascending" | "descending" {
    if (!params.sortable) return "none";
    if (params.columnKey !== params.sortKey) return "none";
    return params.sortDir === "asc" ? "ascending" : "descending";
}

export function formatTablePercent(
    value: number | null | undefined,
    options?: { decimals?: number; signed?: boolean; fallback?: string },
): string {
    return formatPercent(value, {
        decimals: options?.decimals,
        signed: options?.signed,
        fallback: options?.fallback ?? "—",
    });
}

export function formatTableNumber(
    value: number | null | undefined,
    decimals = 2,
    fallback = "—",
): string {
    if (value == null) return fallback;
    return value.toFixed(decimals);
}

export function tableHeaderAlignClass(key: string): string {
    if (key === "status" || key === "enabled") return "text-center";
    if (METRIC_KEYS.has(key)) return "text-right";
    return "text-left";
}

export function tableCellAlignClass(key: string): string {
    if (key === "status" || key === "enabled") return "text-center";
    if (METRIC_KEYS.has(key)) return "text-right font-mono tabular-nums";
    return "text-left";
}

export function stickyFirstColumnClass(params: {
    isFirst: boolean;
    isHeader: boolean;
    selected?: boolean;
}): string {
    if (!params.isFirst) return "";

    if (params.isHeader) {
        // Keep the top-left corner cell pinned in both axes so body cells cannot overdraw it.
        return "sticky left-0 top-0 z-[70] bg-card";
    }

    if (params.selected) {
        return "sticky left-0 z-[20] bg-primary/5";
    }

    return "sticky left-0 z-[20] bg-card group-hover:bg-primary/2";
}

export function stateMessageClasses(params: {
    fullHeight: boolean;
    compact: boolean;
}): string {
    const layoutClass = params.fullHeight
        ? "flex-1 flex items-center justify-center"
        : "text-center";
    const spacingClass = params.compact ? "py-4" : "py-8";
    return [layoutClass, spacingClass, "text-sm text-muted-foreground"].join(" ");
}
