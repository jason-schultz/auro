export type Granularity = "M1" | "M5" | "M15" | "H1" | "H4" | "D";

export const ALL_GRANULARITIES: Granularity[] = ["M1", "M5", "M15", "H1", "H4", "D"];
export const MTF_GRANULARITIES: Granularity[] = ["H4", "H1", "M15"];

export function isGranularity(value: string): value is Granularity {
    return ALL_GRANULARITIES.includes(value as Granularity);
}