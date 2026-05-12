# Datatable Freeze Policy

This project has a frozen datatable contract for shared behavior across:
- Backtests
- Pipeline
- Strategies

## Purpose

Prevent regressions from one-off table tweaks and keep behavior consistent.

## Source Of Truth

All shared table contracts and behavior live in src/lib/ui.ts:
- Column contracts (BACKTEST_COLUMN_SETS, PIPELINE_COLUMNS, STRATEGIES_COLUMNS)
- Width tokens (TABLE_WIDTH_TOKENS)
- Alignment and sticky rules
- Sort accessibility helper (ariaSortForColumn)
- Shared table formatters

## Change Rules

When changing shared table behavior:
1. Update src/lib/ui.ts first.
2. Apply changes in table views only through shared helpers.
3. Update helper tests in tests/datatable-ui-helpers.test.ts.
4. Update structure/mount tests in tests/vitest/datatable-structure.vitest.ts when relevant.
5. For sticky or overlap fixes, keep tests/e2e/sticky-first-column.spec.ts passing.

## Avoid

- Per-view ad hoc width/alignment classes that duplicate shared behavior.
- Custom sort aria behavior implemented directly in a single view.
- Divergent first-column sticky logic between tables.

## Acceptance Checklist For Table Changes

- Shared contract updated (if needed)
- Bun tests pass: bun test
- Vitest mount tests pass: bun run test:views
- Build passes: bun run build
- If sticky behavior touched: bun run test:e2e
