import { expect, test } from "@playwright/test";

function buildStrategy(index: number) {
    const instrument = index % 2 === 0 ? "EUR_USD" : "AUD_USD";

    return {
        id: `s-${index}`,
        strategy_type: index % 2 === 0 ? "trend_following" : "mean_reversion",
        instrument,
        granularity: index % 3 === 0 ? "H4" : "H1",
        parameters:
            index % 2 === 0
                ? {
                      fast_period: 10,
                      slow_period: 30,
                      stop_loss: -0.02,
                      take_profit: 0.03,
                  }
                : {
                      ma_period: 20,
                      entry_threshold: -0.01,
                      exit_threshold: -0.003,
                      stop_loss: -0.015,
                  },
        enabled: index % 4 !== 0,
        max_position_size: "1000",
        created_at: "2026-05-11T10:00:00Z",
        updated_at: "2026-05-11T10:00:00Z",
        backtest_run_id: null,
        source: "pipeline",
        pipeline_score: 0.8,
        backtest_stats: {
            total_return: 0.1,
            win_rate: 0.55,
            sharpe_ratio: 1.1,
            max_drawdown: 0.08,
            num_trades: 40,
            avg_win: 0.03,
            avg_loss: -0.02,
        },
        oos_stats: {
            oos_sharpe: 0.7,
            oos_num_trades: 12,
            oos_return: 0.06,
            sharpe_retention: 0.65,
        },
        live_stats: {
            num_trades: 8,
            wins: 5,
            losses: 3,
            win_rate: 0.625,
            total_return: 0.03,
            avg_win: 0.02,
            avg_loss: -0.015,
        },
    };
}

test("sticky first header cell stays on top while scrolling", async ({ page }) => {
    await page.route("**/api/live/strategies", async (route) => {
        const strategies = Array.from({ length: 30 }, (_, i) => buildStrategy(i + 1));

        await route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({
                strategies,
                count: strategies.length,
            }),
        });
    });

    await page.goto("/strategies");

    const tableScroller = page.locator("main .overflow-auto.h-full").first();
    await expect(tableScroller).toBeVisible();

    const firstHeaderCell = page.locator("thead th").first();
    await expect(firstHeaderCell).toBeVisible();

    await tableScroller.evaluate((el) => {
        el.scrollTop = 380;
        el.scrollLeft = 240;
    });

    const stickyState = await firstHeaderCell.evaluate((cell) => {
        const rect = cell.getBoundingClientRect();
        const x = rect.left + Math.min(24, rect.width / 2);
        const y = rect.top + Math.min(12, rect.height / 2);
        const topElement = document.elementFromPoint(x, y);

        return {
            isTopMostHeader: topElement?.closest("th") === cell,
            hasStickyClass: cell.className.includes("sticky"),
        };
    });

    expect(stickyState.hasStickyClass).toBe(true);
    expect(stickyState.isTopMostHeader).toBe(true);
});
