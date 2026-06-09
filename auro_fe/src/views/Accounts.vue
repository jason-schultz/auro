<template>
    <main class="p-6">
        <div class="mb-6 flex items-center justify-between">
            <h1 class="text-lg font-semibold text-foreground">Accounts</h1>
            <button
                class="text-xs text-muted-foreground hover:text-foreground transition-colors"
                :disabled="loading"
                @click="handleRefresh"
            >
                {{ loading ? "Refreshing…" : "Refresh" }}
            </button>
        </div>

        <div v-if="error" class="mb-4 rounded border border-red-500/30 bg-red-500/10 px-4 py-2 text-xs text-red-400">
            {{ error }}
        </div>

        <div class="flex flex-col gap-4">
            <div
                v-for="broker in brokers"
                :key="broker.broker"
                class="rounded-lg border border-border bg-card"
            >
                <!-- Card header -->
                <div class="flex items-center justify-between border-b border-border px-5 py-3">
                    <div class="flex items-center gap-3">
                        <span class="text-sm font-semibold text-foreground">{{ broker.display_name }}</span>
                        <span v-if="broker.error" class="text-[10px] text-muted-foreground font-mono">{{ broker.error }}</span>
                    </div>
                    <div class="flex items-center gap-3">
                        <button
                            v-if="broker.broker === 'wealthsimple'"
                            class="text-[10px] text-muted-foreground hover:text-foreground transition-colors"
                            @click="toggleEdit"
                        >
                            {{ editing ? "Cancel" : "Edit" }}
                        </button>
                        <span class="flex items-center gap-1.5">
                            <span
                                class="h-1.5 w-1.5 rounded-full"
                                :class="broker.connected ? 'bg-emerald-500 animate-pulse' : 'bg-[#3a3a4a]'"
                            />
                            <span class="text-[10px] text-muted-foreground">
                                {{ broker.broker === 'wealthsimple'
                                    ? (broker.connected ? "Manual entry" : "Not configured")
                                    : (broker.connected ? "Connected" : "Not connected") }}
                            </span>
                        </span>
                    </div>
                </div>

                <!-- ── Wealthsimple edit form ── -->
                <div v-if="broker.broker === 'wealthsimple' && editing" class="divide-y divide-border">
                    <div v-for="(row, i) in editRows" :key="i" class="p-5">
                        <!-- Account row -->
                        <div class="mb-1 grid grid-cols-[120px_110px_70px_1fr_1fr_1fr_28px] gap-2 items-center text-[10px] text-muted-foreground uppercase tracking-wider">
                            <span>Type</span><span>Acct #</span><span>Currency</span>
                            <span>Cash</span><span>Market Value</span><span>Total Equity</span><span />
                        </div>
                        <div class="grid grid-cols-[120px_110px_70px_1fr_1fr_1fr_28px] gap-2 items-center">
                            <select v-model="row.account_type" :class="INPUT">
                                <option v-for="t in ACCOUNT_TYPES" :key="t" :value="t">{{ t }}</option>
                            </select>
                            <input v-model="row.account_number" placeholder="optional" :class="INPUT" />
                            <select v-model="row.currency" :class="INPUT">
                                <option>CAD</option><option>USD</option>
                            </select>
                            <input v-model.number="row.cash" type="number" placeholder="0.00" step="0.01" :class="INPUT" />
                            <input v-model.number="row.market_value" type="number" placeholder="0.00" step="0.01" :class="INPUT" />
                            <input v-model.number="row.total_equity" type="number" placeholder="0.00" step="0.01" :class="INPUT" />
                            <button class="flex items-center justify-center text-muted-foreground hover:text-red-400 transition-colors text-sm" @click="removeRow(i)">×</button>
                        </div>

                        <!-- Positions sub-section -->
                        <div class="mt-4 ml-2">
                            <div class="mb-1 text-[10px] text-muted-foreground uppercase tracking-wider">Positions</div>
                            <div v-if="row.positions.length > 0" class="mb-2 flex flex-col gap-1">
                                <div class="grid grid-cols-[90px_80px_1fr_1fr_28px] gap-2 items-center text-[10px] text-muted-foreground">
                                    <span>Symbol</span><span>Shares</span><span>Avg Cost</span><span>Current Price</span><span />
                                </div>
                                <div
                                    v-for="(pos, j) in row.positions"
                                    :key="j"
                                    class="grid grid-cols-[90px_80px_1fr_1fr_28px] gap-2 items-center"
                                >
                                    <input v-model="pos.symbol" placeholder="AAPL" :class="INPUT + ' uppercase'" />
                                    <input v-model.number="pos.shares" type="number" placeholder="0" step="0.0001" :class="INPUT" />
                                    <input v-model.number="pos.avg_cost" type="number" placeholder="0.00" step="0.01" :class="INPUT" />
                                    <input v-model.number="pos.current_price" type="number" placeholder="0.00" step="0.01" :class="INPUT" />
                                    <button class="flex items-center justify-center text-muted-foreground hover:text-red-400 transition-colors text-sm" @click="removePosition(i, j)">×</button>
                                </div>
                            </div>
                            <button class="text-[10px] text-muted-foreground hover:text-foreground transition-colors" @click="addPosition(i)">+ Add position</button>
                        </div>
                    </div>

                    <!-- Form footer -->
                    <div class="flex items-center gap-3 px-5 py-3">
                        <button class="text-xs text-muted-foreground hover:text-foreground transition-colors" @click="addRow">+ Add account</button>
                        <div class="ml-auto flex items-center gap-2">
                            <span v-if="saveError" class="text-xs text-red-400">{{ saveError }}</span>
                            <button
                                class="rounded px-3 py-1 text-xs bg-primary/10 text-amber-400 hover:bg-primary/20 transition-colors disabled:opacity-50"
                                :disabled="saving"
                                @click="saveWealthsimple"
                            >{{ saving ? "Saving…" : "Save" }}</button>
                        </div>
                    </div>
                </div>

                <!-- ── Read mode (non-WS or WS with data) ── -->
                <template v-else-if="broker.accounts.length > 0">
                    <!-- For Wealthsimple: per-account sections with positions -->
                    <template v-if="broker.broker === 'wealthsimple'">
                        <div
                            v-for="wsAcct in wsAccounts"
                            :key="wsAcct.id"
                            class="border-b border-border/50 last:border-0"
                        >
                            <!-- Account summary row -->
                            <div class="grid grid-cols-[1fr_auto_auto_auto_auto] gap-6 px-5 py-3 text-xs">
                                <span class="font-mono text-foreground">
                                    {{ wsAcct.account_number ? `${wsAcct.account_type} (${wsAcct.account_number})` : wsAcct.account_type }}
                                </span>
                                <span class="text-muted-foreground">{{ wsAcct.currency }}</span>
                                <span class="text-muted-foreground">Cash <span class="font-mono text-foreground">{{ formatAmount(wsAcct.cash, wsAcct.currency) }}</span></span>
                                <span class="text-muted-foreground">Holdings <span class="font-mono text-foreground">{{ formatAmount(wsAcct.market_value, wsAcct.currency) }}</span></span>
                                <span class="text-muted-foreground">Equity <span class="font-mono text-foreground">{{ formatAmount(wsAcct.total_equity, wsAcct.currency) }}</span></span>
                            </div>
                            <!-- Positions sub-table -->
                            <div v-if="wsAcct.positions.length > 0" class="border-t border-border/30 bg-muted/5 overflow-x-auto">
                                <table class="w-full text-xs">
                                    <thead>
                                        <tr class="text-[10px] text-muted-foreground uppercase tracking-wider">
                                            <th class="px-8 py-1.5 text-left font-medium">Symbol</th>
                                            <th class="px-4 py-1.5 text-right font-medium">Shares</th>
                                            <th class="px-4 py-1.5 text-right font-medium">Avg Cost</th>
                                            <th class="px-4 py-1.5 text-right font-medium">Current</th>
                                            <th class="px-4 py-1.5 text-right font-medium">Mkt Value</th>
                                            <th class="px-4 py-1.5 text-right font-medium">Unrealized P&L</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        <tr v-for="pos in wsAcct.positions" :key="pos.id" class="border-t border-border/20">
                                            <td class="px-8 py-1.5 font-mono font-medium text-foreground">{{ pos.symbol }}</td>
                                            <td class="px-4 py-1.5 text-right font-mono text-foreground">{{ pos.shares }}</td>
                                            <td class="px-4 py-1.5 text-right font-mono text-muted-foreground">{{ formatAmount(pos.avg_cost, wsAcct.currency) }}</td>
                                            <td class="px-4 py-1.5 text-right font-mono text-foreground">{{ formatAmount(pos.current_price, wsAcct.currency) }}</td>
                                            <td class="px-4 py-1.5 text-right font-mono text-foreground">{{ formatAmount(marketValue(pos), wsAcct.currency) }}</td>
                                            <td class="px-4 py-1.5 text-right font-mono" :class="pnlColor(pos)">
                                                {{ formatPnl(pos, wsAcct.currency) }}
                                            </td>
                                        </tr>
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </template>

                    <!-- OANDA / Questrade: flat account table -->
                    <template v-else>
                        <div class="overflow-x-auto">
                            <table class="w-full text-xs">
                                <thead>
                                    <tr class="border-b border-border text-[10px] text-muted-foreground uppercase tracking-wider">
                                        <th class="px-5 py-2 text-left font-medium">Account</th>
                                        <th class="px-5 py-2 text-left font-medium">Type</th>
                                        <th class="px-5 py-2 text-left font-medium">Currency</th>
                                        <th class="px-5 py-2 text-right font-medium">Cash</th>
                                        <th v-if="hasMarketValue(broker)" class="px-5 py-2 text-right font-medium">Market Value</th>
                                        <th class="px-5 py-2 text-right font-medium">Total Equity</th>
                                        <th v-if="hasBuyingPower(broker)" class="px-5 py-2 text-right font-medium">Buying Power</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <tr
                                        v-for="acct in broker.accounts"
                                        :key="acct.id"
                                        class="border-b border-border/50 last:border-0 hover:bg-muted/5 transition-colors"
                                    >
                                        <td class="px-5 py-3 font-mono text-foreground">{{ acct.name }}</td>
                                        <td class="px-5 py-3 text-muted-foreground">{{ acct.account_type }}</td>
                                        <td class="px-5 py-3 text-muted-foreground">{{ acct.currency }}</td>
                                        <td class="px-5 py-3 text-right font-mono text-foreground">{{ formatAmount(acct.cash, acct.currency) }}</td>
                                        <td v-if="hasMarketValue(broker)" class="px-5 py-3 text-right font-mono text-foreground">{{ formatAmount(acct.market_value, acct.currency) }}</td>
                                        <td class="px-5 py-3 text-right font-mono text-foreground">{{ formatAmount(acct.total_equity, acct.currency) }}</td>
                                        <td v-if="hasBuyingPower(broker)" class="px-5 py-3 text-right font-mono text-foreground">{{ formatAmount(acct.buying_power, acct.currency) }}</td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </template>
                </template>

                <!-- Empty state -->
                <div v-else-if="broker.broker !== 'wealthsimple' || !editing" class="px-5 py-4 text-xs text-muted-foreground">
                    <span v-if="broker.broker === 'wealthsimple'">No accounts — click Edit to add balances manually.</span>
                    <span v-else>No accounts — configure connection to see balances.</span>
                </div>
            </div>

            <template v-if="loading && brokers.length === 0">
                <div v-for="n in 3" :key="n" class="h-24 animate-pulse rounded-lg border border-border bg-card" />
            </template>
        </div>
    </main>
</template>

<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useBrokers, type BrokerStatus } from "@/composables/useBrokers";
import { api } from "@/services/api";

const { brokers, loading, error, refresh } = useBrokers();

// ── Detailed WS data (includes positions) ──────────────────────────────────
interface WsPosition {
    id: number;
    account_id: number;
    symbol: string;
    shares: number;
    avg_cost: number | null;
    current_price: number | null;
    updated_at: string;
}
interface WsAccount {
    id: number;
    account_type: string;
    account_number: string | null;
    currency: string;
    cash: number | null;
    market_value: number | null;
    total_equity: number | null;
    updated_at: string;
    positions: WsPosition[];
}
const wsAccounts = ref<WsAccount[]>([]);

async function fetchWsAccounts() {
    wsAccounts.value = await api.get<WsAccount[]>("/brokers/wealthsimple");
}

onMounted(fetchWsAccounts);

async function handleRefresh() {
    await Promise.all([refresh(), fetchWsAccounts()]);
}

// ── Edit form ───────────────────────────────────────────────────────────────
const ACCOUNT_TYPES = ["TFSA", "LIRA", "RRSP", "FHSA", "RESP", "Personal", "Cash", "Crypto", "RRIF", "Non-registered"];

interface EditPosition {
    symbol: string;
    shares: number | null;
    avg_cost: number | null;
    current_price: number | null;
}
interface EditRow {
    account_type: string;
    account_number: string;
    currency: string;
    cash: number | null;
    market_value: number | null;
    total_equity: number | null;
    positions: EditPosition[];
}

const editing = ref(false);
const saving = ref(false);
const saveError = ref<string | null>(null);
const editRows = ref<EditRow[]>([]);

function blankRow(): EditRow {
    return { account_type: "TFSA", account_number: "", currency: "CAD", cash: null, market_value: null, total_equity: null, positions: [] };
}
function blankPosition(): EditPosition {
    return { symbol: "", shares: null, avg_cost: null, current_price: null };
}

function toggleEdit() {
    if (editing.value) {
        editing.value = false;
        saveError.value = null;
        return;
    }
    editRows.value = wsAccounts.value.length
        ? wsAccounts.value.map((a) => ({
              account_type: a.account_type,
              account_number: a.account_number ?? "",
              currency: a.currency,
              cash: a.cash,
              market_value: a.market_value,
              total_equity: a.total_equity,
              positions: a.positions.map((p) => ({
                  symbol: p.symbol,
                  shares: p.shares,
                  avg_cost: p.avg_cost,
                  current_price: p.current_price,
              })),
          }))
        : [blankRow()];
    editing.value = true;
    saveError.value = null;
}

function addRow() { editRows.value.push(blankRow()); }
function removeRow(i: number) { editRows.value.splice(i, 1); }
function addPosition(i: number) { editRows.value[i].positions.push(blankPosition()); }
function removePosition(i: number, j: number) { editRows.value[i].positions.splice(j, 1); }

async function saveWealthsimple() {
    saving.value = true;
    saveError.value = null;
    try {
        await api.put("/brokers/wealthsimple", {
            accounts: editRows.value.map((r) => ({
                account_type: r.account_type,
                account_number: r.account_number || null,
                currency: r.currency,
                cash: r.cash,
                market_value: r.market_value,
                total_equity: r.total_equity,
                positions: r.positions
                    .filter((p) => p.symbol.trim())
                    .map((p) => ({
                        symbol: p.symbol.trim().toUpperCase(),
                        shares: p.shares ?? 0,
                        avg_cost: p.avg_cost,
                        current_price: p.current_price,
                    })),
            })),
        });
        editing.value = false;
        await Promise.all([refresh(), fetchWsAccounts()]);
    } catch (e) {
        saveError.value = e instanceof Error ? e.message : "Save failed";
    } finally {
        saving.value = false;
    }
}

// ── Position calculations ───────────────────────────────────────────────────
function marketValue(pos: WsPosition): number | null {
    if (pos.current_price === null) return null;
    return pos.shares * pos.current_price;
}

function unrealizedPnl(pos: WsPosition): number | null {
    if (pos.avg_cost === null || pos.current_price === null) return null;
    return (pos.current_price - pos.avg_cost) * pos.shares;
}

function pnlColor(pos: WsPosition): string {
    const pnl = unrealizedPnl(pos);
    if (pnl === null) return "text-muted-foreground";
    return pnl >= 0 ? "text-emerald-400" : "text-red-400";
}

function formatPnl(pos: WsPosition, currency: string): string {
    const pnl = unrealizedPnl(pos);
    if (pnl === null) return "—";
    const formatted = formatAmount(Math.abs(pnl), currency);
    return pnl >= 0 ? `+${formatted}` : `-${formatted}`;
}

// ── Shared input class ──────────────────────────────────────────────────────
const INPUT = "rounded border border-border bg-background px-2 py-1 text-xs text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-primary/50 w-full";

// ── Helpers ─────────────────────────────────────────────────────────────────
function hasMarketValue(broker: BrokerStatus): boolean {
    return broker.accounts.some((a) => a.market_value !== null);
}
function hasBuyingPower(broker: BrokerStatus): boolean {
    return broker.accounts.some((a) => a.buying_power !== null);
}
function formatAmount(value: number | null, currency: string): string {
    if (value === null || value === undefined) return "—";
    return new Intl.NumberFormat("en-CA", {
        style: "currency",
        currency,
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    }).format(value);
}
</script>
