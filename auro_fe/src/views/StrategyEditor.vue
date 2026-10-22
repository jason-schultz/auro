<template>
    <main class="p-6">
        <div class="flex items-center justify-between mb-4">
            <div class="flex items-center gap-3">
                <router-link
                    to="/strategies"
                    class="text-sm text-muted-foreground hover:text-foreground"
                >
                    ← Strategies
                </router-link>
                <h2 class="text-lg font-semibold text-foreground">Strategy Editor</h2>
            </div>
            <div class="flex items-center gap-2">
                <span v-if="draftStatus" class="text-[10px] text-muted-foreground">
                    {{ draftStatus }}
                </span>
                <select
                    :class="INPUT_CLASS"
                    class="w-48"
                    :value="currentDraftId ?? ''"
                    @change="onDraftSelected($event)"
                >
                    <option value="">— new strategy —</option>
                    <option v-for="d in drafts" :key="d.id" :value="d.id">
                        {{ d.name }}
                    </option>
                </select>
                <input
                    v-model="strategyName"
                    placeholder="strategy name"
                    :class="INPUT_CLASS"
                    class="w-48"
                />
                <button
                    type="button"
                    class="rounded bg-primary/10 px-2.5 py-1 text-xs text-primary hover:bg-primary/20 transition-colors"
                    @click="saveDraft"
                >
                    Save
                </button>
                <button
                    v-if="currentDraftId"
                    type="button"
                    class="rounded px-2 py-1 text-xs text-muted-foreground hover:text-red-400 transition-colors"
                    @click="deleteDraft"
                >
                    Delete
                </button>
            </div>
        </div>

        <div class="grid grid-cols-1 xl:grid-cols-3 gap-4">
            <!-- Left: chart + validation -->
            <div class="xl:col-span-2 space-y-4">
                <div class="flex items-center gap-2">
                    <select v-model="instrument" :class="INPUT_CLASS" class="w-44 font-mono">
                        <option v-for="i in instruments" :key="i" :value="i">
                            {{ i }}
                        </option>
                    </select>
                    <select v-model="granularity" :class="INPUT_CLASS" class="w-24 font-mono">
                        <option v-for="g in ALL_GRANULARITIES" :key="g" :value="g">
                            {{ g }}
                        </option>
                    </select>
                </div>

                <EditorCandleChart
                    :instrument="instrument"
                    :granularity="granularity"
                    :count="300"
                    :components="components"
                    :config="config"
                />

                <!-- Validation panel -->
                <section class="fr-card p-4">
                    <div class="flex items-center justify-between mb-3">
                        <div class="fr-section-label mb-0 pb-0 border-b-0">Validation</div>
                        <span class="text-[10px] text-muted-foreground">
                            backtest → walk-forward → Monte Carlo, same gates as the pipeline
                        </span>
                    </div>

                    <p v-if="validationError" class="text-xs text-amber-400 mb-3">
                        {{ validationError }}
                    </p>
                    <p v-if="runError" class="text-xs text-red-400 mb-3">{{ runError }}</p>

                    <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
                        <div
                            v-for="stage in STAGE_ORDER"
                            :key="stage"
                            class="rounded-md bg-background p-3"
                        >
                            <div class="flex items-center justify-between mb-2">
                                <span class="text-xs text-foreground font-mono">{{
                                    stageLabel(stage)
                                }}</span>
                                <BadgePill
                                    v-if="stageResults[stage]"
                                    :label="stageResults[stage]!.status"
                                    :extra-class="
                                        stageResults[stage]!.status === 'passed'
                                            ? 'bg-emerald-500/15 text-emerald-400'
                                            : 'bg-red-500/15 text-red-400'
                                    "
                                />
                            </div>

                            <button
                                type="button"
                                class="w-full rounded px-2 py-1.5 text-xs transition-colors"
                                :class="
                                    stageUnlocked(stage) && !running
                                        ? 'bg-primary/10 text-primary hover:bg-primary/20'
                                        : 'bg-muted/30 text-muted-foreground cursor-not-allowed'
                                "
                                :disabled="!stageUnlocked(stage) || running != null"
                                @click="runStage(stage)"
                            >
                                {{ running === stage ? "Running…" : `Run ${stageLabel(stage)}` }}
                            </button>

                            <div v-if="stageResults[stage]" class="mt-2 space-y-1">
                                <p
                                    v-if="stageResults[stage]!.failure_reason"
                                    class="text-[10px] text-red-400"
                                >
                                    {{ stageResults[stage]!.failure_reason }}
                                </p>
                                <div
                                    v-for="[key, value] in statEntries(stageResults[stage]!)"
                                    :key="key"
                                    class="flex justify-between text-[10px]"
                                >
                                    <span class="text-muted-foreground">{{ key }}</span>
                                    <span class="font-mono text-foreground">{{ value }}</span>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div
                        v-if="allPassed"
                        class="mt-3 rounded-md bg-emerald-500/10 border border-emerald-500/20 p-3 text-xs text-emerald-400"
                    >
                        All gates passed. Promote from the
                        <router-link to="/pipeline" class="underline">Pipeline</router-link>
                        page (config {{ configId?.slice(0, 8) }}…).
                    </div>
                </section>
            </div>

            <!-- Right: builder -->
            <div class="space-y-4">
                <!-- Components -->
                <section class="fr-card p-4">
                    <div class="flex items-center justify-between mb-3">
                        <div class="fr-section-label mb-0 pb-0 border-b-0">Components</div>
                        <select
                            :class="INPUT_CLASS"
                            class="w-44"
                            :value="''"
                            @change="onAddComponent($event)"
                        >
                            <option value="" disabled>+ add component</option>
                            <option v-for="c in COMPONENT_CATALOG" :key="c.type" :value="c.type">
                                {{ c.label }}
                            </option>
                        </select>
                    </div>

                    <p v-if="components.length === 0" class="text-xs text-muted-foreground py-4 text-center">
                        Add a component to start building.
                    </p>

                    <div
                        v-for="(comp, idx) in components"
                        :key="idx"
                        class="rounded-md bg-background p-3 mb-2"
                    >
                        <div class="flex items-center justify-between mb-2">
                            <div class="flex items-center gap-2">
                                <input
                                    v-model="comp.name"
                                    :class="INPUT_CLASS"
                                    class="w-20 font-mono"
                                    title="Component name — referenced as name.port"
                                />
                                <span class="text-xs text-muted-foreground">
                                    {{ specFor(comp.type)?.label ?? comp.type }}
                                </span>
                            </div>
                            <button
                                type="button"
                                class="text-[10px] text-muted-foreground hover:text-red-400"
                                @click="removeComponent(idx)"
                            >
                                remove
                            </button>
                        </div>

                        <div class="grid grid-cols-2 gap-2">
                            <label
                                v-for="param in specFor(comp.type)?.params ?? []"
                                :key="param.key"
                                class="block"
                            >
                                <span class="text-[10px] text-muted-foreground block mb-0.5">
                                    {{ param.label }}
                                </span>
                                <select
                                    v-if="param.kind === 'choice'"
                                    v-model="comp.params[param.key]"
                                    :class="INPUT_CLASS"
                                    class="w-full"
                                >
                                    <option v-for="t in param.options ?? []" :key="t" :value="t">
                                        {{ t.toUpperCase() }}
                                    </option>
                                </select>
                                <input
                                    v-else
                                    v-model.number="comp.params[param.key]"
                                    type="number"
                                    :min="param.min"
                                    :step="param.step ?? (param.kind === 'int' ? 1 : 0.1)"
                                    :class="INPUT_CLASS"
                                    class="w-full font-mono"
                                />
                            </label>
                        </div>
                        <p class="text-[10px] text-muted-foreground mt-2 font-mono">
                            ports: {{ (specFor(comp.type)?.ports ?? []).map((p) => `${comp.name}.${p}`).join(", ") }}
                        </p>
                    </div>
                </section>

                <!-- Entry / Exit -->
                <section class="fr-card p-4">
                    <div class="fr-section-label mb-3">Entry / Exit</div>

                    <div class="flex items-center gap-4 mb-3">
                        <label class="flex items-center gap-1.5 text-xs text-foreground">
                            <input v-model="longEnabled" type="checkbox" />
                            Long side
                        </label>
                        <label class="flex items-center gap-1.5 text-xs text-foreground">
                            <input v-model="shortEnabled" type="checkbox" />
                            Short side
                        </label>
                    </div>

                    <template v-if="longEnabled">
                        <div class="text-[10px] text-muted-foreground mb-1">Entry — long</div>
                        <PortRefNode v-model="entryLong" :ports="availablePorts" class="mb-3" />
                        <div class="text-[10px] text-muted-foreground mb-1">Exit — long</div>
                        <PortRefNode v-model="exitLong" :ports="availablePorts" class="mb-3" />
                    </template>

                    <template v-if="shortEnabled">
                        <div class="text-[10px] text-muted-foreground mb-1">Entry — short</div>
                        <PortRefNode v-model="entryShort" :ports="availablePorts" class="mb-3" />
                        <div class="text-[10px] text-muted-foreground mb-1">Exit — short</div>
                        <PortRefNode v-model="exitShort" :ports="availablePorts" />
                    </template>
                </section>

                <!-- Risk -->
                <section class="fr-card p-4">
                    <div class="fr-section-label mb-3">Stop / Sizing</div>

                    <div class="grid grid-cols-2 gap-2 mb-2">
                        <label class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">Stop type</span>
                            <select v-model="stop.type" :class="INPUT_CLASS" class="w-full" @change="onStopTypeChange">
                                <option value="FixedPct">Fixed %</option>
                                <option value="AtrMultiple">ATR multiple</option>
                                <option value="FromComponent">From component</option>
                            </select>
                        </label>

                        <label v-if="stop.type === 'FixedPct'" class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">
                                Stop pct (negative)
                            </span>
                            <input
                                v-model.number="stop.params.pct"
                                type="number"
                                step="0.005"
                                max="0"
                                :class="INPUT_CLASS"
                                class="w-full font-mono"
                            />
                        </label>

                        <template v-if="stop.type === 'AtrMultiple'">
                            <label class="block">
                                <span class="text-[10px] text-muted-foreground block mb-0.5">k × ATR</span>
                                <input
                                    v-model.number="stop.params.k"
                                    type="number"
                                    step="0.5"
                                    min="0.5"
                                    :class="INPUT_CLASS"
                                    class="w-full font-mono"
                                />
                            </label>
                            <label class="block">
                                <span class="text-[10px] text-muted-foreground block mb-0.5">ATR period</span>
                                <input
                                    v-model.number="stop.params.period"
                                    type="number"
                                    min="2"
                                    :class="INPUT_CLASS"
                                    class="w-full font-mono"
                                />
                            </label>
                        </template>

                        <label v-if="stop.type === 'FromComponent'" class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">Component</span>
                            <select v-model="stop.params.component" :class="INPUT_CLASS" class="w-full font-mono">
                                <option v-for="c in components" :key="c.name" :value="c.name">
                                    {{ c.name }}
                                </option>
                            </select>
                        </label>

                        <label class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">Risk % per trade</span>
                            <input
                                v-model.number="sizingPct"
                                type="number"
                                step="0.005"
                                min="0.001"
                                max="0.05"
                                :class="INPUT_CLASS"
                                class="w-full font-mono"
                            />
                        </label>

                        <label class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">
                                Max notional × NAV (blank = engine default 0.15)
                            </span>
                            <input
                                :value="maxNotionalPct ?? ''"
                                type="number"
                                step="0.05"
                                min="0.05"
                                max="4"
                                :class="INPUT_CLASS"
                                class="w-full font-mono"
                                @input="onMaxNotionalInput($event)"
                            />
                        </label>

                        <label class="block">
                            <span class="text-[10px] text-muted-foreground block mb-0.5">
                                Max hold bars (blank = none)
                            </span>
                            <input
                                :value="maxHoldBars ?? ''"
                                type="number"
                                min="1"
                                :class="INPUT_CLASS"
                                class="w-full font-mono"
                                @input="onMaxHoldInput($event)"
                            />
                        </label>
                    </div>
                </section>

                <!-- JSON preview -->
                <section class="fr-card p-4">
                    <button
                        type="button"
                        class="fr-section-label mb-0 pb-0 border-b-0 w-full text-left"
                        @click="showJson = !showJson"
                    >
                        Config JSON {{ showJson ? "▾" : "▸" }}
                    </button>
                    <pre
                        v-if="showJson"
                        class="mt-3 text-[10px] font-mono text-muted-foreground overflow-auto max-h-80 bg-background rounded-md p-3"
                        >{{ config ? JSON.stringify(config, null, 2) : "— invalid config —" }}</pre
                    >
                </section>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from "vue";

import EditorCandleChart from "@/components/editor/EditorCandleChart.vue";
import PortRefNode from "@/components/editor/PortRefNode.vue";
import BadgePill from "@/components/ui/BadgePill.vue";
import { ALL_GRANULARITIES } from "@/lib/granularities";
import { COMPONENT_CATALOG, componentSpec } from "@/lib/strategyCatalog";
import { INPUT_CLASS } from "@/lib/ui";
import { api, getApiErrorMessage } from "@/services/api";
import { useStrategyDrafts } from "@/composables/useStrategyDrafts";
import {
    STAGE_ORDER,
    useStrategyEditor,
    type StageName,
    type StageResult,
} from "@/composables/useStrategyEditor";

const {
    strategyName,
    instrument,
    granularity,
    components,
    longEnabled,
    shortEnabled,
    entryLong,
    entryShort,
    exitLong,
    exitShort,
    stop,
    sizingPct,
    maxNotionalPct,
    maxHoldBars,
    availablePorts,
    addComponent,
    removeComponent,
    validationError,
    config,
    configId,
    running,
    stageResults,
    runError,
    stageUnlocked,
    runStage,
    serialize,
    hydrate,
    reset,
} = useStrategyEditor();

const { drafts, refresh: refreshDrafts, create, update, remove } = useStrategyDrafts();

const instruments = ref<string[]>([instrument.value]);
const showJson = ref(false);
const currentDraftId = ref<string | null>(null);
const draftStatus = ref<string | null>(null);

async function saveDraft() {
    if (!strategyName.value.trim()) {
        draftStatus.value = "name required to save";
        return;
    }

    try {
        if (currentDraftId.value) {
            await update(
                currentDraftId.value,
                strategyName.value.trim(),
                serialize(),
                instrument.value,
                granularity.value,
            );
        } else {
            const draft = await create(
                strategyName.value.trim(),
                serialize(),
                instrument.value,
                granularity.value,
            );
            currentDraftId.value = draft.id;
        }
        draftStatus.value = `saved ${new Date().toLocaleTimeString()}`;
    } catch (e) {
        draftStatus.value = getApiErrorMessage(e, "save failed");
    }
}

function onDraftSelected(event: Event) {
    const id = (event.target as HTMLSelectElement).value;
    if (!id) {
        currentDraftId.value = null;
        reset();
        draftStatus.value = null;
        return;
    }

    const draft = drafts.value.find((d) => d.id === id);
    if (!draft) return;

    currentDraftId.value = draft.id;
    strategyName.value = draft.name;
    hydrate(draft.definition);
    if (draft.last_instrument) instrument.value = draft.last_instrument;
    if (draft.last_granularity) granularity.value = draft.last_granularity;
    draftStatus.value = null;
}

async function deleteDraft() {
    if (!currentDraftId.value) return;
    try {
        await remove(currentDraftId.value);
        currentDraftId.value = null;
        reset();
        draftStatus.value = "deleted";
    } catch (e) {
        draftStatus.value = getApiErrorMessage(e, "delete failed");
    }
}

const specFor = componentSpec;

const allPassed = computed(() => STAGE_ORDER.every((s) => stageResults[s]?.status === "passed"));

function stageLabel(stage: StageName): string {
    switch (stage) {
        case "backtest":
            return "Backtest";
        case "walk_forward":
            return "Walk-Forward";
        case "monte_carlo":
            return "Monte Carlo";
    }
}

function statEntries(result: StageResult): Array<[string, string]> {
    if (!result.stats) return [];
    return Object.entries(result.stats)
        .filter(([, v]) => typeof v === "number")
        .map(([k, v]) => [k, formatStat(v as number)]);
}

function formatStat(v: number): string {
    if (Number.isInteger(v)) return String(v);
    return v.toFixed(4);
}

function onAddComponent(event: Event) {
    const select = event.target as HTMLSelectElement;
    if (select.value) addComponent(select.value);
    select.value = "";
}

function onStopTypeChange() {
    switch (stop.type) {
        case "FixedPct":
            stop.params = { pct: -0.02 };
            break;
        case "AtrMultiple":
            stop.params = { k: 3.0, period: 14 };
            break;
        case "FromComponent":
            stop.params = { component: components.value[0]?.name ?? "" };
            break;
    }
}

function onMaxNotionalInput(event: Event) {
    const value = (event.target as HTMLInputElement).value;
    maxNotionalPct.value = value === "" ? null : Number(value);
}

function onMaxHoldInput(event: Event) {
    const value = (event.target as HTMLInputElement).value;
    maxHoldBars.value = value === "" ? null : Number(value);
}

onMounted(async () => {
    void refreshDrafts();
    try {
        const body = await api.get<{ instruments: Array<string | { name: string }> }>(
            "/instruments",
        );
        const names = body.instruments
            .map((i) => (typeof i === "string" ? i : i.name))
            .filter(Boolean)
            .sort();
        if (names.length > 0) instruments.value = names;
    } catch {
        // Fall back to the default single instrument; chart still works.
    }
});
</script>
