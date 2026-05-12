export function formatPercent(
    value: number | null | undefined,
    options?: { decimals?: number; signed?: boolean; fallback?: string },
): string {
    const decimals = options?.decimals ?? 2;
    const signed = options?.signed ?? false;
    const fallback = options?.fallback ?? "—";

    if (value == null) return fallback;

    const sign = signed && value >= 0 ? "+" : "";
    return `${sign}${(value * 100).toFixed(decimals)}%`;
}

export function formatCadCurrency(value: string | number): string {
    const numeric = typeof value === "number" ? value : parseFloat(value);

    return new Intl.NumberFormat("en-CA", {
        style: "currency",
        currency: "CAD",
        minimumFractionDigits: 2,
    }).format(numeric);
}
