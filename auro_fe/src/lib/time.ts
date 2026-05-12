export function formatDurationCompact(
    startStr: string | null | undefined,
    endStr: string | null | undefined,
): string | null {
    if (!startStr || !endStr) return null;

    const start = new Date(startStr).getTime();
    const end = new Date(endStr).getTime();
    if (Number.isNaN(start) || Number.isNaN(end) || end < start) return null;

    const diffMin = Math.floor((end - start) / 60000);
    if (diffMin < 60) return `${diffMin}m`;

    const diffHr = Math.floor(diffMin / 60);
    if (diffHr < 24) return `${diffHr}h`;

    const diffDays = Math.floor(diffHr / 24);
    const remainingHr = diffHr - diffDays * 24;
    return remainingHr === 0 ? `${diffDays}d` : `${diffDays}d ${remainingHr}h`;
}

export function timeAgoCompact(dateStr: string): string {
    const now = new Date();
    const then = new Date(dateStr);
    const diffMs = now.getTime() - then.getTime();
    const diffMin = Math.floor(diffMs / 60000);

    if (diffMin < 1) return "just now";
    if (diffMin < 60) return `${diffMin}m ago`;

    const diffHr = Math.floor(diffMin / 60);
    if (diffHr < 24) return `${diffHr}h ago`;

    const diffDays = Math.floor(diffHr / 24);
    return `${diffDays}d ago`;
}
