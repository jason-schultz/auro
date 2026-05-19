import { computed, onMounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { api } from "@/services/api";
import { formatPercent } from "@/lib/format";
import { getInstrumentDecimals } from "@/lib/instruments";
import { TRADE_DETAIL_LABEL_EXPLAINERS } from "@/lib/metricExplainers";
import { expectancy as calculateExpectancy } from "@/lib/metrics";
import {
    buildEntryNarrativeText,
    buildExitNarrativeText,
    buildStrategyPrimerText,
} from "@/lib/tradeNarrative";
import type { StatGridItem } from "@/lib/ui";
import type { TradeDetailResponse } from "@/types/trade";

export function useTradeDetail() {
    const route = useRoute();
    const detail = ref<TradeDetailResponse | null>(null);
    const loading = ref(true);
    const error = ref<string | null>(null);

    async function load(id: string) {
        loading.value = true;
        error.value = null;
        try {
            detail.value = await api.get<TradeDetailResponse>(`/live/trades/${id}`);
        } catch (e) {
            error.value = `Failed to load trade: ${(e as Error).message}`;
        } finally {
            loading.value = false;
        }
    }

    onMounted(() => {
        const id = route.params.id as string;
        if (id) load(id);
    });

    watch(
        () => route.params.id,
        (newId) => {
            if (newId) load(newId as string);
        },
    );

    const exitDisplay = computed(() => {
        if (!detail.value) return "-";
        const exit = detail.value.trade.exit_price;
        if (exit == null || exit <= 0) return "-";
        return `$${formatPrice(exit)}`;
    });

    const pnlDisplay = computed(() => {
        if (!detail.value) return "-";
        const pnl = detail.value.trade.pnl_percent;
        if (pnl == null) return "-";
        const sign = pnl >= 0 ? "+" : "";
        return `${sign}${(pnl * 100).toFixed(2)}%`;
    });

    const pnlClass = computed(() => {
        if (!detail.value) return "text-foreground";
        const pnl = detail.value.trade.pnl_percent;
        if (pnl == null) return "text-foreground";
        return pnl >= 0 ? "text-emerald-400" : "text-red-400";
    });

    const duration = computed(() => {
        if (!detail.value) return null;
        const t = detail.value.trade;
        if (!t.exit_time) return null;
        const start = new Date(t.entry_time).getTime();
        const end = new Date(t.exit_time).getTime();
        if (Number.isNaN(start) || Number.isNaN(end) || end < start) return null;
        const min = Math.floor((end - start) / 60000);
        if (min < 60) return `${min}m`;
        const hr = Math.floor(min / 60);
        if (hr < 24) return `${hr}h`;
        const d = Math.floor(hr / 24);
        const remHr = hr - d * 24;
        return remHr === 0 ? `${d}d` : `${d}d ${remHr}h`;
    });

    const strategyTypeLabel = computed(() => {
        const t = detail.value?.strategy?.strategy_type;
        if (!t) return "-";
        if (t === "trend_following") return "Trend Following";
        if (t === "mean_reversion") return "Mean Reversion";
        return t;
    });

    const tradeVsAvgLabel = computed(() => {
        if (!detail.value?.backtest) return "-";
        const trade = detail.value.trade.pnl_percent;
        if (trade == null) return "-";
        const ref = trade >= 0 ? detail.value.backtest.avg_win : detail.value.backtest.avg_loss;
        if (ref == null || ref === 0) return "-";
        const ratio = trade / ref;
        return `${ratio.toFixed(2)}x avg ${trade >= 0 ? "win" : "loss"}`;
    });

    const tradeVsAvgClass = computed(() => {
        if (!detail.value?.backtest) return "text-foreground";
        const trade = detail.value.trade.pnl_percent;
        if (trade == null) return "text-foreground";
        return trade >= 0 ? "text-emerald-400" : "text-red-400";
    });

    const liveExpectancy = computed(() => {
        const live = detail.value?.live_aggregate;
        if (!live) return 0;
        return calculateExpectancy(live.win_rate, live.avg_win, live.avg_loss);
    });

    const backtestExpectancy = computed(() => {
        const bt = detail.value?.backtest;
        if (!bt || bt.win_rate == null || bt.avg_win == null || bt.avg_loss == null) {
            return null;
        }
        return calculateExpectancy(bt.win_rate, bt.avg_win, bt.avg_loss);
    });

    const winRateDelta = computed(() => {
        const live = detail.value?.live_aggregate;
        const bt = detail.value?.backtest;
        if (!live || !bt || bt.win_rate == null) return null;
        return live.win_rate - bt.win_rate;
    });

    const expectancyDelta = computed(() => {
        const btExp = backtestExpectancy.value;
        if (btExp == null) return null;
        return liveExpectancy.value - btExp;
    });

    const avgWinDelta = computed(() => {
        const live = detail.value?.live_aggregate;
        const bt = detail.value?.backtest;
        if (!live || !bt || bt.avg_win == null) return null;
        return live.avg_win - bt.avg_win;
    });

    const avgLossDelta = computed(() => {
        const live = detail.value?.live_aggregate;
        const bt = detail.value?.backtest;
        if (!live || !bt || bt.avg_loss == null) return null;
        return live.avg_loss - bt.avg_loss;
    });

    const edgeStatus = computed(() => {
        const live = detail.value?.live_aggregate;
        const btExp = backtestExpectancy.value;
        if (!live || btExp == null) return null;

        if (live.num_trades < 5) {
            return {
                label: `Insufficient data (${live.num_trades}/5 trades)`,
                color: "bg-muted text-muted-foreground",
            };
        }

        const liveExp = liveExpectancy.value;

        if (liveExp <= 0 && btExp <= 0) {
            return {
                label: "Negative expectancy",
                color: "bg-red-500/10 text-red-400",
            };
        }

        if (btExp <= 0) {
            return {
                label: "Live exceeds backtest",
                color: "bg-emerald-500/10 text-emerald-400",
            };
        }

        const ratio = liveExp / btExp;
        if (ratio >= 0.85) {
            return {
                label: "Edge holding",
                color: "bg-emerald-500/10 text-emerald-400",
            };
        }
        if (ratio >= 0.5) {
            return {
                label: "Edge degrading",
                color: "bg-amber-500/10 text-amber-400",
            };
        }
        return {
            label: "Edge broken",
            color: "bg-red-500/10 text-red-400",
        };
    });

    const eli5EntryText = computed(() => {
        if (!detail.value) return "";
        const strategyType = detail.value.strategy?.strategy_type ?? "";
        const strategyParameters = detail.value.strategy?.parameters as Record<string, unknown> | null;
        return buildEntryNarrativeText({
            strategyType,
            strategyParameters,
            entryReason: detail.value.trade.entry_reason,
        });
    });

    const eli5ExitText = computed(() => {
        if (!detail.value) return "";
        const strategyParameters = detail.value.strategy?.parameters as Record<string, unknown> | null;
        return buildExitNarrativeText({
            exitReason: detail.value.trade.exit_reason,
            stopLossStateAtClose: detail.value.trade.stop_loss_state_at_close,
            entryPrice: detail.value.trade.entry_price,
            exitPrice: detail.value.trade.exit_price,
            strategyParameters,
        });
    });

    const strategyPrimerText = computed(() => {
        if (!detail.value) return "";
        const strategyType = detail.value.strategy?.strategy_type ?? "";
        const strategyParameters = detail.value.strategy?.parameters as Record<string, unknown> | null;
        return buildStrategyPrimerText(strategyType, strategyParameters);
    });

    const instrumentRegimeText = computed(() => {
        const regime = detail.value?.trade.regime_at_entry;
        if (!regime || regime === "unknown") {
            return "Instrument regime at entry: unknown (not captured for this trade).";
        }
        return `Instrument regime at entry: ${regime}.`;
    });

    const regimePlaceholderText = computed(() => {
        const instrument = detail.value?.trade.instrument ?? "";
        const category = instrument.endsWith("_USD")
            ? "cross-asset"
            : instrument.includes("_")
                ? "fx"
                : "unknown";

        return [
            `Sector regime (placeholder): not wired yet for ${instrument || "this instrument"} (${category}).`,
            "Market regime (placeholder): not wired yet.",
            "Exit-time regime (placeholder): will be populated once we capture regime on exit.",
        ];
    });

    const tradeMetricItems = computed<StatGridItem[]>(() => {
        if (!detail.value) return [];

        return [
            {
                label: "Entry",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS.Entry,
                value: `$${formatPrice(detail.value.trade.entry_price)}`,
                meta: formatTime(detail.value.trade.entry_time),
            },
            {
                label: "Exit",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS.Exit,
                value: exitDisplay.value,
                meta: detail.value.trade.exit_time ? formatTime(detail.value.trade.exit_time) : "-",
            },
            {
                label: "P&L",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["P&L"],
                value: pnlDisplay.value,
                valueClass: pnlClass.value,
            },
            {
                label: "Duration",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS.Duration,
                value: duration.value || "-",
            },
        ];
    });

    const strategyMetricItems = computed<StatGridItem[]>(() => {
        if (!detail.value?.strategy) return [];
        return [
            {
                label: "Granularity",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS.Granularity,
                value: detail.value.strategy.granularity || "-",
            },
            {
                label: "Max Position",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Max Position"],
                value: detail.value.strategy.max_position_size || "-",
            },
        ];
    });

    const liveMetricItems = computed<StatGridItem[]>(() => {
        const live = detail.value?.live_aggregate;
        if (!live) return [];

        return [
            {
                label: "# Trades",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["# Trades"],
                value: String(live.num_trades),
                meta: `(${live.wins}W / ${live.losses}L)`,
            },
            {
                label: "Live Win Rate",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Live Win Rate"],
                value: formatPct(live.win_rate),
                meta: winRateDelta.value != null ? `${formatDelta(winRateDelta.value)} vs BT` : undefined,
                metaClass: deltaClass(winRateDelta.value),
            },
            {
                label: "Live Total Return",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Live Total Return"],
                value: formatPct(live.total_return),
                valueClass: live.total_return >= 0 ? "text-emerald-400" : "text-red-400",
            },
            {
                label: "Live Expectancy",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Live Expectancy"],
                value: formatPct(liveExpectancy.value),
                valueClass: liveExpectancy.value >= 0 ? "text-emerald-400" : "text-red-400",
                meta: expectancyDelta.value != null ? `${formatDelta(expectancyDelta.value)} vs BT` : undefined,
                metaClass: deltaClass(expectancyDelta.value),
            },
            {
                label: "Live Avg Win",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Live Avg Win"],
                value: formatPct(live.avg_win),
                valueClass: "text-emerald-400",
                meta: avgWinDelta.value != null ? `${formatDelta(avgWinDelta.value)} vs BT` : undefined,
                metaClass: deltaClass(avgWinDelta.value),
            },
            {
                label: "Live Avg Loss",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Live Avg Loss"],
                value: formatPct(live.avg_loss),
                valueClass: "text-red-400",
                meta: avgLossDelta.value != null ? `${formatDelta(avgLossDelta.value)} vs BT` : undefined,
                metaClass: avgLossDelta.value != null
                    ? deltaClass(-avgLossDelta.value)
                    : "text-muted-foreground",
            },
        ];
    });

    const backtestMetricItems = computed<StatGridItem[]>(() => {
        if (!detail.value?.backtest) return [];
        const bt = detail.value.backtest;

        return [
            {
                label: "Sharpe Ratio",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Sharpe Ratio"],
                value: formatStat(bt.sharpe_ratio, 2),
                valueClass: sharpeClass(bt.sharpe_ratio),
            },
            {
                label: "Win Rate",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Win Rate"],
                value: formatPct(bt.win_rate),
            },
            {
                label: "Total Return",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Total Return"],
                value: formatPct(bt.total_return),
                valueClass: (bt.total_return ?? 0) >= 0 ? "text-emerald-400" : "text-red-400",
            },
            {
                label: "Max Drawdown",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Max Drawdown"],
                value: formatPct(bt.max_drawdown),
                valueClass: "text-red-400",
            },
            {
                label: "Avg Win",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Avg Win"],
                value: formatPct(bt.avg_win),
                valueClass: "text-emerald-400",
            },
            {
                label: "Avg Loss",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Avg Loss"],
                value: formatPct(bt.avg_loss),
                valueClass: "text-red-400",
            },
            {
                label: "# Trades",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["# Trades"],
                value: String(bt.num_trades ?? "-"),
            },
            {
                label: "Trade vs Avg",
                explainer: TRADE_DETAIL_LABEL_EXPLAINERS["Trade vs Avg"],
                value: tradeVsAvgLabel.value,
                valueClass: tradeVsAvgClass.value,
            },
        ];
    });

    function deltaClass(delta: number | null): string {
        if (delta == null) return "text-muted-foreground";
        if (Math.abs(delta) < 0.001) return "text-muted-foreground";
        return delta >= 0 ? "text-emerald-400" : "text-red-400";
    }

    function formatDelta(delta: number | null): string {
        if (delta == null) return "-";
        const sign = delta >= 0 ? "+" : "";
        return `${sign}${(delta * 100).toFixed(2)}%`;
    }

    function formatPrice(price: number | null | undefined): string {
        if (price == null || price <= 0) return "-";
        const inst = detail.value?.trade.instrument || "";
        return price.toFixed(getDecimals(inst));
    }

    function getDecimals(instrument: string): number {
        return getInstrumentDecimals(instrument);
    }

    function formatTime(iso: string): string {
        if (!iso) return "-";
        const d = new Date(iso);
        return d.toLocaleString("en-CA", {
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
        });
    }

    function formatPct(value: number | null | undefined): string {
        return formatPercent(value, { signed: true, fallback: "-" });
    }

    function formatStat(value: number | null | undefined, decimals: number): string {
        if (value == null) return "-";
        return value.toFixed(decimals);
    }

    function sharpeClass(value: number | null | undefined): string {
        if (value == null) return "text-foreground";
        if (value >= 1.0) return "text-emerald-400";
        if (value >= 0.5) return "text-amber-400";
        return "text-red-400";
    }

    function formatParamValue(value: unknown): string {
        if (value === null || value === undefined) return "-";
        if (typeof value === "number") {
            return Math.abs(value) < 1 && value !== 0
                ? value.toFixed(4)
                : value.toString();
        }
        return String(value);
    }

    return {
        detail,
        loading,
        error,
        strategyTypeLabel,
        edgeStatus,
        strategyPrimerText,
        eli5EntryText,
        eli5ExitText,
        instrumentRegimeText,
        regimePlaceholderText,
        tradeMetricItems,
        strategyMetricItems,
        liveMetricItems,
        backtestMetricItems,
        formatParamValue,
    };
}
