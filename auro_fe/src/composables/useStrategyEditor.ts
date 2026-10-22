import { computed, reactive, ref, watch } from "vue";

import {
    componentSpec,
    defaultParams,
    type CompositeStrategyConfig,
    type PortRef,
    type StopConfig,
} from "../lib/strategyCatalog";
import { getApiErrorMessage, opusApi } from "../services/api";
import type { DraftDefinition } from "./useStrategyDrafts";

export interface ComponentInstance {
    name: string;
    type: string;
    params: Record<string, number | string>;
}

export type StageName = "backtest" | "walk_forward" | "monte_carlo";

export interface StageResult {
    stage: StageName;
    status: "passed" | "failed" | string;
    stats: Record<string, unknown> | null;
    failure_reason: string | null;
    evaluation_id: string | null;
}

export const STAGE_ORDER: StageName[] = ["backtest", "walk_forward", "monte_carlo"];


export function useStrategyEditor() {
    const strategyName = ref("");
    const instrument = ref("EUR_USD");
    const granularity = ref("H1");
    const components = ref<ComponentInstance[]>([]);
    const longEnabled = ref(true);
    const shortEnabled = ref(true);
    const entryLong = ref<PortRef>("");
    const entryShort = ref<PortRef>("");
    const exitLong = ref<PortRef>("");
    const exitShort = ref<PortRef>("");
    const stop = reactive<StopConfig>({ type: "FixedPct", params: { pct: -0.02 } });
    const sizingPct = ref(0.01);
    // Per-strategy notional cap (fraction of NAV); null = engine default.
    const maxNotionalPct = ref<number | null>(null);
    const maxHoldBars = ref<number | null>(null);

    // Validation run state
    const configId = ref<string | null>(null);
    const running = ref<StageName | null>(null);
    const stageResults = reactive<Partial<Record<StageName, StageResult>>>({});
    const runError = ref<string | null>(null);

    const availablePorts = computed<string[]>(() =>
        components.value.flatMap((c) => {
            const spec = componentSpec(c.type);
            return spec ? spec.ports.map((p) => `${c.name}.${p}`) : [];
        }),
    );

    function addComponent(type: string) {
        const spec = componentSpec(type);
        if (!spec) return;

        // Default name: lowercased type, deduped with a counter (tf, tf2, ...)
        const base = type.replace(/[a-z]/g, "").toLowerCase() || type.toLowerCase();
        let name = base;
        let n = 2;
        while (components.value.some((c) => c.name === name)) {
            name = `${base}${n++}`;
        }

        components.value.push({ name, type, params: defaultParams(spec) });

        // Seed empty selectors with the first port so selects aren't blank.
        const firstPort = `${name}.${spec.ports[0]}`;
        if (entryLong.value === "") entryLong.value = firstPort;
        if (entryShort.value === "") entryShort.value = firstPort;
        if (exitLong.value === "") exitLong.value = firstPort;
        if (exitShort.value === "") exitShort.value = firstPort;
    }

    function removeComponent(index: number) {
        components.value.splice(index, 1);
    }

    const validationError = computed<string | null>(() => {
        if (components.value.length === 0) return "Add at least one component.";
        if (!longEnabled.value && !shortEnabled.value) {
            return "Enable at least one side (long or short).";
        }
        const names = components.value.map((c) => c.name);
        if (new Set(names).size !== names.length) return "Component names must be unique.";
        if (names.some((n) => !/^[a-z][a-z0-9_]*$/.test(n))) {
            return "Component names must be lowercase identifiers (a-z, 0-9, _).";
        }
        return null;
    });

    const config = computed<CompositeStrategyConfig | null>(() => {
        if (validationError.value) return null;
        if (availablePorts.value.length === 0) return null;

        return {
            strategy_id: null,
            strategy_name: strategyName.value || null,
            version: "v1_composite",
            instrument: instrument.value,
            granularity: granularity.value,
            components: Object.fromEntries(
                components.value.map((c) => [c.name, { type: c.type, params: c.params }]),
            ),
            // Disabled sides are omitted entirely; the engine reads a missing
            // side as "never fires."
            entry: {
                ...(longEnabled.value ? { long: entryLong.value } : {}),
                ...(shortEnabled.value ? { short: entryShort.value } : {}),
            },
            exit: {
                ...(longEnabled.value ? { long: exitLong.value } : {}),
                ...(shortEnabled.value ? { short: exitShort.value } : {}),
            },
            stop: { type: stop.type, params: { ...stop.params } },
            sizing: {
                type: "RiskPct",
                params: {
                    pct: sizingPct.value,
                    ...(maxNotionalPct.value != null ? { max_notional_pct: maxNotionalPct.value } : {}),
                },
            },
            max_hold_bars: maxHoldBars.value,
        };
    });

    // Any edit invalidates previous validation results: the saved config no
    // longer matches what's on screen, so stages must be re-run from scratch.
    watch(
        config,
        () => {
            configId.value = null;
            delete stageResults.backtest;
            delete stageResults.walk_forward;
            delete stageResults.monte_carlo;
            runError.value = null;
        },
        { deep: true },
    );

    function stageUnlocked(stage: StageName): boolean {
        const idx = STAGE_ORDER.indexOf(stage);
        if (idx === 0) return config.value != null;
        const prev = stageResults[STAGE_ORDER[idx - 1]];
        return prev?.status === "passed";
    }

    /** Editor state → instrument-agnostic draft definition. */
    function serialize(): DraftDefinition {
        return {
            version: 1,
            components: components.value.map((c) => ({
                name: c.name,
                type: c.type,
                params: { ...c.params },
            })),
            longEnabled: longEnabled.value,
            shortEnabled: shortEnabled.value,
            entryLong: entryLong.value,
            entryShort: entryShort.value,
            exitLong: exitLong.value,
            exitShort: exitShort.value,
            stop: { type: stop.type, params: { ...stop.params } },
            sizingPct: sizingPct.value,
            maxNotionalPct: maxNotionalPct.value,
            maxHoldBars: maxHoldBars.value,
        };
    }

    /** Load a draft definition back into the editor. */
    function hydrate(definition: DraftDefinition) {
        components.value = (definition.components ?? []).map((c) => ({
            name: c.name,
            type: c.type,
            params: { ...c.params },
        }));
        longEnabled.value = definition.longEnabled ?? true;
        shortEnabled.value = definition.shortEnabled ?? true;
        entryLong.value = (definition.entryLong as PortRef) ?? "";
        entryShort.value = (definition.entryShort as PortRef) ?? "";
        exitLong.value = (definition.exitLong as PortRef) ?? "";
        exitShort.value = (definition.exitShort as PortRef) ?? "";
        stop.type = (definition.stop?.type as StopConfig["type"]) ?? "FixedPct";
        stop.params = { ...(definition.stop?.params ?? { pct: -0.02 }) };
        sizingPct.value = definition.sizingPct ?? 0.01;
        maxNotionalPct.value = definition.maxNotionalPct ?? null;
        maxHoldBars.value = definition.maxHoldBars ?? null;
    }

    function reset() {
        components.value = [];
        longEnabled.value = true;
        shortEnabled.value = true;
        entryLong.value = "";
        entryShort.value = "";
        exitLong.value = "";
        exitShort.value = "";
        stop.type = "FixedPct";
        stop.params = { pct: -0.02 };
        sizingPct.value = 0.01;
        maxNotionalPct.value = null;
        maxHoldBars.value = null;
        strategyName.value = "";
    }

    async function runStage(stage: StageName) {
        if (!config.value || running.value) return;
        running.value = stage;
        runError.value = null;

        try {
            if (!configId.value) {
                const created = await opusApi.post<{ config_id: string }>("/strategy-configs", {
                    instrument: instrument.value,
                    granularity: granularity.value,
                    parameters: config.value,
                });
                configId.value = created.config_id;
            }

            const result = await opusApi.post<StageResult>(
                `/strategy-configs/${configId.value}/run/${stage}`,
                {},
            );
            stageResults[stage] = result;
        } catch (e) {
            runError.value = getApiErrorMessage(e, `Failed to run ${stage}`);
        } finally {
            running.value = null;
        }
    }

    return {
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
    };
}
