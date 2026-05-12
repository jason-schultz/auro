export type DataPanelState = "loading" | "empty" | "ready";

export function resolveDataPanelState(
    loading: boolean,
    empty: boolean,
): DataPanelState {
    if (loading) return "loading";
    if (empty) return "empty";
    return "ready";
}

export function viewHeaderClass(compact: boolean): string {
    return compact
        ? "flex items-center justify-between mb-3"
        : "flex items-center justify-between mb-4";
}

export function filterToolbarClass(inline: boolean, tight: boolean): string {
    const gapClass = tight ? "gap-2" : "gap-3";
    const marginClass = inline ? "mb-0" : "mb-3";
    return `flex items-center ${gapClass} ${marginClass}`;
}

export function filterToolbarDividerClass(): string {
    return "w-px h-4 bg-border";
}

export function dataTableHeadClass(sticky: boolean): string {
    return sticky ? "sticky top-0 bg-card" : "bg-card";
}
