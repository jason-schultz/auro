import { computed, ref } from "vue";
import { api, opusApi } from "../services/api";
import { BACKTEST_COLUMN_SETS } from "../lib/ui";
import type { BacktestResultsResponse, BacktestRun } from "../types/backtest";
import type { PipelineConfig, PipelineStatusResponse } from "../types/pipeline";

export function useBacktests() {
    const results = ref<BacktestRun[]>([]);
    const loading = ref(true);
    const running = ref(false);

    const sourceFilter = ref<"grid" | "pipeline">("grid");
    const statusFilter = ref("valid");
    const instrumentFilter = ref("");
    const sortKey = ref("sharpe_ratio");
    const sortDir = ref<"asc" | "desc">("desc");
    const strategyFilter = ref("all");
    const granularityFilter = ref("all");

    const runInstrument = ref("EUR_USD");
    const runTimeframe = ref("H1");

    const lastRunResult = ref<
        | {
            instrument: string;
            timeframe: string;
            results: { valid: number; verify: number; failed: number };
        }
        | null
    >(null);

    const columns = computed(() => {
        if (strategyFilter.value === "trend_following") {
            return BACKTEST_COLUMN_SETS.trendFollowing;
        }

        if (strategyFilter.value === "mean_reversion") {
            return BACKTEST_COLUMN_SETS.meanReversion;
        }

        if (sourceFilter.value === "pipeline") {
            return BACKTEST_COLUMN_SETS.pipeline;
        }

        return BACKTEST_COLUMN_SETS.default;
    });

    const sortedResults = computed(() => {
        const sorted = [...results.value];
        sorted.sort((a, b) => {
            let aVal: string | number;
            let bVal: string | number;

            const paramKeys = [
                "ma_period",
                "entry_threshold",
                "exit_threshold",
                "stop_loss",
                "fast_period",
                "slow_period",
                "take_profit",
            ];

            if (paramKeys.includes(sortKey.value)) {
                aVal = Number(a.parameters[sortKey.value as keyof typeof a.parameters] ?? 0);
                bVal = Number(b.parameters[sortKey.value as keyof typeof b.parameters] ?? 0);
            } else {
                aVal = ((a as unknown) as Record<string, string | number | undefined>)[sortKey.value] ?? "";
                bVal = ((b as unknown) as Record<string, string | number | undefined>)[sortKey.value] ?? "";
            }

            if (typeof aVal === "string" && typeof bVal === "string") {
                return sortDir.value === "asc" ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
            }

            const aNum = typeof aVal === "number" ? aVal : Number(aVal) || 0;
            const bNum = typeof bVal === "number" ? bVal : Number(bVal) || 0;
            return sortDir.value === "asc" ? aNum - bNum : bNum - aNum;
        });

        return sorted;
    });

    function toggleSort(key: string) {
        if (sortKey.value === key) {
            sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
        } else {
            sortKey.value = key;
            sortDir.value = "desc";
        }
    }

    function normalizePipelineConfig(c: PipelineConfig): BacktestRun {
        const btEval = c.evaluations.find((e) => e.stage === "backtest");
        const btStats = btEval?.stats ?? {};

        return {
            id: c.config_id,
            strategy_name: `${c.instrument} ${c.strategy_type} ${c.granularity}`,
            strategy_type: c.strategy_type,
            instrument: c.instrument,
            granularity: c.granularity,
            parameters: c.parameters ?? ({} as BacktestRun["parameters"]),
            total_return: (btStats.total_return as number) ?? 0,
            win_rate: (btStats.win_rate as number) ?? 0,
            sharpe_ratio: (btStats.sharpe as number) ?? 0,
            max_drawdown: (btStats.max_drawdown as number) ?? 0,
            num_trades: (btStats.num_trades as number) ?? 0,
            avg_win: 0,
            avg_loss: 0,
            status: c.status ?? "pending",
            reason_flagged: c.failure_reason,
            execution_duration_ms: 0,
            _pipeline: c,
        };
    }

    async function loadResults() {
        loading.value = true;

        try {
            if (sourceFilter.value === "pipeline") {
                const data = await opusApi.get<PipelineStatusResponse>("/pipeline");
                let filtered = data.configs;

                if (strategyFilter.value !== "all") {
                    filtered = filtered.filter((c) => c.strategy_type === strategyFilter.value);
                }

                if (granularityFilter.value !== "all") {
                    filtered = filtered.filter((c) => c.granularity === granularityFilter.value);
                }

                if (instrumentFilter.value) {
                    filtered = filtered.filter((c) => c.instrument === instrumentFilter.value);
                }

                results.value = filtered.map(normalizePipelineConfig);
            } else {
                const stratParam = strategyFilter.value !== "all" ? `&strategy_type=${strategyFilter.value}` : "";
                const granParam = granularityFilter.value !== "all" ? `&granularity=${granularityFilter.value}` : "";
                const instParam = instrumentFilter.value ? `&instrument=${instrumentFilter.value}` : "";

                const data = await api.get<BacktestResultsResponse>(
                    `/backtest/results?status=${statusFilter.value}&limit=500${stratParam}${granParam}${instParam}`,
                );

                results.value = data.results;
            }
        } catch (e) {
            console.error("Failed to load results:", e);
        } finally {
            loading.value = false;
        }
    }

    async function runGridSearch() {
        running.value = true;
        lastRunResult.value = null;

        try {
            const data = await api.post<{ instrument: string; results: { valid: number; verify: number; failed: number } }>(
                `/backtest/run?instrument=${runInstrument.value}&timeframe=${runTimeframe.value}`,
                {},
            );

            lastRunResult.value = { ...data, timeframe: runTimeframe.value };
            await loadResults();
        } catch (e) {
            console.error("Grid search failed:", e);
        } finally {
            running.value = false;
        }
    }

    return {
        results,
        loading,
        running,
        sourceFilter,
        statusFilter,
        instrumentFilter,
        sortKey,
        sortDir,
        strategyFilter,
        granularityFilter,
        runInstrument,
        runTimeframe,
        lastRunResult,
        columns,
        sortedResults,
        toggleSort,
        loadResults,
        runGridSearch,
    };
}
