import { computed, ref } from "vue";
import { api, getApiErrorMessage } from "@/services/api";
import { formatPercent } from "@/lib/format";
import { formatDurationCompact } from "@/lib/time";
import { pnlClass, slStateClass, formatIndicatorValue } from "@/lib/domain-ui";
import { strategyTypeLabel } from "@/lib/strategy";
import { ariaSortForColumn, JOURNAL_COLUMNS } from "@/lib/ui";
import type { JournalTrade, JournalResponse } from "@/types/trade";

export function useJournal() {
    const trades = ref<JournalTrade[]>([]);
    const loading = ref(true);
    const errorMessage = ref("");

    const statusFilter = ref("all");
    const strategyFilter = ref("all");
    const granularityFilter = ref("all");

    const sortKey = ref("entry_time");
    const sortDir = ref<"asc" | "desc">("desc");
    const page = ref(1);
    const PAGE_SIZE = 50;

    const expandedId = ref<string | null>(null);

    const statusOptions = [
        { id: "all", label: "All" },
        { id: "closed", label: "Closed" },
        { id: "open", label: "Open" },
    ];

    const strategyOptions = [
        { id: "all", label: "All" },
        { id: "trend_following", label: "Trend" },
        { id: "mean_reversion", label: "Mean Rev" },
    ];

    const granularityOptions = [
        { id: "all", label: "All" },
        { id: "H4", label: "H4" },
        { id: "H1", label: "H1" },
        { id: "M15", label: "M15" },
        { id: "M5", label: "M5" },
    ];

    const columns = JOURNAL_COLUMNS;

    async function load() {
        loading.value = true;
        errorMessage.value = "";
        try {
            const data = await api.get<JournalResponse>("/live/trades?limit=500");
            trades.value = data.trades;
        } catch (e) {
            errorMessage.value = getApiErrorMessage(e, "Failed to load trades");
        } finally {
            loading.value = false;
        }
    }

    const closedCount = computed(() => trades.value.filter((t) => t.status === "closed").length);
    const openCount = computed(() => trades.value.filter((t) => t.status === "open").length);

    const filteredTrades = computed(() => {
        let result = trades.value;

        if (statusFilter.value !== "all") {
            result = result.filter((t) => t.status === statusFilter.value);
        }
        if (strategyFilter.value !== "all") {
            result = result.filter((t) => t.strategy_type === strategyFilter.value);
        }
        if (granularityFilter.value !== "all") {
            result = result.filter((t) => t.strategy_granularity === granularityFilter.value);
        }

        const dir = sortDir.value === "asc" ? 1 : -1;
        return [...result].sort((a, b) => {
            const av = (a as Record<string, unknown>)[sortKey.value];
            const bv = (b as Record<string, unknown>)[sortKey.value];
            if (av == null && bv == null) return 0;
            if (av == null) return 1;
            if (bv == null) return -1;
            return av < bv ? -dir : av > bv ? dir : 0;
        });
    });

    const totalPages = computed(() =>
        Math.max(1, Math.ceil(filteredTrades.value.length / PAGE_SIZE)),
    );

    const paginatedTrades = computed(() => {
        const start = (page.value - 1) * PAGE_SIZE;
        return filteredTrades.value.slice(start, start + PAGE_SIZE);
    });

    function setSortKey(key: string) {
        if (sortKey.value === key) {
            sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
        } else {
            sortKey.value = key;
            sortDir.value = "desc";
        }
        page.value = 1;
    }

    function toggleExpand(id: string) {
        expandedId.value = expandedId.value === id ? null : id;
    }

    function headerClass(key: string, columnIndex: number, sortable: boolean): string {
        return [
            sortable ? "cursor-pointer hover:text-foreground select-none" : "",
            ["pnl_percent", "mae_pct", "mfe_pct", "entry_price"].includes(key)
                ? "text-right"
                : "",
        ]
            .filter(Boolean)
            .join(" ");
    }

    function getAriaSortForColumn(col: { key: string; sortable: boolean }) {
        return ariaSortForColumn({
            sortable: col.sortable,
            columnKey: col.key,
            sortKey: sortKey.value,
            sortDir: sortDir.value,
        });
    }

    function fmtPct(v: number | null): string {
        return formatPercent(v, { signed: true, fallback: "—" });
    }

    function fmtDatetime(v: string | null): string {
        if (!v) return "—";
        return new Date(v).toLocaleString("en-CA", {
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
        });
    }

    function fmtDuration(trade: JournalTrade): string {
        const end = trade.exit_time ?? new Date().toISOString();
        return formatDurationCompact(trade.entry_time, end) ?? "—";
    }

    return {
        trades,
        loading,
        errorMessage,
        statusFilter,
        strategyFilter,
        granularityFilter,
        statusOptions,
        strategyOptions,
        granularityOptions,
        sortKey,
        sortDir,
        page,
        totalPages,
        expandedId,
        columns,
        closedCount,
        openCount,
        filteredTrades,
        paginatedTrades,
        load,
        setSortKey,
        toggleExpand,
        headerClass,
        getAriaSortForColumn,
        fmtPct,
        fmtDatetime,
        fmtDuration,
        // shared helpers re-exported so the view imports from one place
        pnlClass,
        slStateClass,
        formatIndicatorValue,
        strategyTypeLabel,
    };
}
