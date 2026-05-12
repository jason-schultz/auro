export function expectancy(winRate: number, avgWin: number, avgLoss: number): number {
    return winRate * avgWin + (1 - winRate) * avgLoss;
}
