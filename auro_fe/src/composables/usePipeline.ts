import { computed, onMounted, ref } from "vue";
import { opusApi } from "../services/api";
import { strategyTypeLabel } from "../lib/strategy";
import { formatTableNumber } from "../lib/ui";
import type {
    PipelineConfig,
    PipelineStatusResponse,
    PipelineSummary,
} from "../types/pipeline";

export function usePipeline() {
    const loading = ref(false);
    const configs = ref<PipelineConfig[]>([]);
    const summary = ref<PipelineSummary | null>(null);
    const filterStrategy = ref("");
    const filterGranularity = ref("");
    const filterStatus = ref("");
    const filterSource = ref("");
    const sortKey = ref("score");
    const sortDir = ref<"asc" | "desc">("desc");

    const childRankMap = computed(() => {
        const groups = new Map<string, string[]>();
        for (const c of configs.value) {
            if (c.lineage_id == null || c.evo_generation == null) continue;
            const key = `${c.lineage_id}:${c.evo_generation}`;
            const arr = groups.get(key) ?? [];
            arr.push(c.config_id);
            groups.set(key, arr);
        }

        const result = new Map<string, number>();
        for (const [key, ids] of groups) {
            ids.forEach((id, i) => result.set(`${key}:${id}`, i + 1));
        }
        return result;
    });

    function childRank(c: PipelineConfig): number {
        if (c.lineage_id == null || c.evo_generation == null) return 0;
        return childRankMap.value.get(`${c.lineage_id}:${c.evo_generation}:${c.config_id}`) ?? 0;
    }

    const filtered = computed(() => {
        return configs.value.filter((c) => {
            if (filterStrategy.value && c.strategy_type !== filterStrategy.value) return false;
            if (filterGranularity.value && c.granularity !== filterGranularity.value) return false;
            if (filterStatus.value && (c.status || "pending") !== filterStatus.value) return false;
            if (filterSource.value === "evo" && c.lineage_id == null) return false;
            if (filterSource.value === "manual" && c.source !== "manual") return false;
            return true;
        });
    });

    const sorted = computed(() => {
        const rows = [...filtered.value];

        rows.sort((a, b) => {
            const aVal = sortValue(a, sortKey.value);
            const bVal = sortValue(b, sortKey.value);

            if (typeof aVal === "string" && typeof bVal === "string") {
                return sortDir.value === "asc"
                    ? aVal.localeCompare(bVal)
                    : bVal.localeCompare(aVal);
            }

            const aNum = typeof aVal === "number" ? aVal : Number(aVal) || 0;
            const bNum = typeof bVal === "number" ? bVal : Number(bVal) || 0;
            return sortDir.value === "asc" ? aNum - bNum : bNum - aNum;
        });

        return rows;
    });

    function toggleSort(key: string) {
        if (sortKey.value === key) {
            sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
        } else {
            sortKey.value = key;
            sortDir.value = "desc";
        }
    }

    function sortValue(c: PipelineConfig, key: string): string | number {
        switch (key) {
            case "instrument":
                return c.instrument;
            case "strategy_type":
                return c.strategy_type;
            case "granularity":
                return c.granularity;
            case "generation":
                return c.evo_generation ?? c.depth ?? -1;
            case "stage":
                return c.stage ?? "";
            case "status":
                return c.status ?? "pending";
            case "sharpe":
                return sharpeStat(c) ?? Number.NEGATIVE_INFINITY;
            case "trades":
                return tradesStat(c) ?? Number.NEGATIVE_INFINITY;
            case "drawdown":
                return drawdownStat(c) ?? Number.NEGATIVE_INFINITY;
            case "score":
                return c.score ?? Number.NEGATIVE_INFINITY;
            case "failure_reason":
                return c.failure_reason ?? "";
            default:
                return "";
        }
    }

    async function load() {
        loading.value = true;
        try {
            const data = await opusApi.get<PipelineStatusResponse>("/pipeline");
            configs.value = data.configs ?? [];
            summary.value = data.summary ?? null;
        } catch (e) {
            console.error("Failed to load pipeline status", e);
        } finally {
            loading.value = false;
        }
    }

    function strategyLabel(type: string) {
        return strategyTypeLabel(type);
    }

    function stageLabel(stage: string | null) {
        if (!stage) return "—";
        return { backtest: "Backtest", walk_forward: "Walk-fwd", monte_carlo: "Monte Carlo" }[stage] ?? stage;
    }

    function statusClass(status: string | null) {
        switch (status) {
            case "passed":
                return "bg-emerald-500/15 text-emerald-400";
            case "failed":
                return "bg-red-500/15 text-red-400";
            case "running":
                return "bg-yellow-500/15 text-yellow-400";
            default:
                return "bg-muted text-muted-foreground";
        }
    }

    function sharpeStat(c: PipelineConfig): number | null {
        if (!c.stats) return null;
        return c.stats.sharpe ?? c.stats.oos_sharpe ?? c.stats.median_sharpe ?? null;
    }

    function tradesStat(c: PipelineConfig): number | null {
        if (!c.stats) return null;
        return c.stats.num_trades ?? c.stats.oos_num_trades ?? null;
    }

    function drawdownStat(c: PipelineConfig): number | null {
        if (!c.stats) return null;
        return c.stats.max_drawdown ?? c.stats.p95_drawdown ?? null;
    }

    function sharpeColor(v: number | null) {
        if (v === null) return "text-muted-foreground";
        if (v >= 2.0) return "text-emerald-400";
        if (v >= 1.0) return "text-primary";
        return "text-red-400";
    }

    function scoreColor(v: number | null | undefined) {
        if (v == null) return "text-muted-foreground";
        if (v >= 2.0) return "text-emerald-400";
        if (v >= 0.5) return "text-primary";
        return "text-yellow-400";
    }

    function fmt(v: number | null) {
        return formatTableNumber(v, 2);
    }

    onMounted(load);

    return {
        loading,
        configs,
        summary,
        filterStrategy,
        filterGranularity,
        filterStatus,
        filterSource,
        filtered,
        sorted,
        sortKey,
        sortDir,
        childRank,
        load,
        toggleSort,
        strategyLabel,
        stageLabel,
        statusClass,
        sharpeStat,
        tradesStat,
        drawdownStat,
        sharpeColor,
        scoreColor,
        fmt,
    };
}
