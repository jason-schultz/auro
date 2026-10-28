# Strategies and assignments: plan (2026-10-27)

Status: **phase 1 steps 1–3 built 2026-10-27** (migration `20261027010000_split_strategies_from_assignments`,
Rust reads in `repositories/live_strategies.rs` via `PARAMETERS_SQL`). Nothing here changes how any live
strategy trades.

## The idea in one paragraph

A **strategy** is a recipe: what to watch, when to buy or sell, where the stop goes, how
long to hold. It names no instrument. An **assignment** says "run this strategy on this
instrument, at this size, and do this when it fires". One strategy can have any number of
assignments. Later, "do this" can be more than an OANDA trade: an alert to buy shares on
Wealthsimple, or an option to open (the strategy as a trigger).

```
Strategy "RSI(2) dip-buy, daily"
   ↑                 ↑                  ↑
Assignment        Assignment         Assignment
SPX500, 1%        NAS100, 0.5%       EU50, 1%
action: OANDA     action: OANDA      action: OANDA
```

## What's wrong today

Checked against the database and code on 2026-10-27.

1. **The recipe is copied per instrument.** `live_strategies.parameters` holds the whole
   recipe. The RSI(2) dip-buy exists three times (SPX500, NAS100, EU50), identical except
   for `instrument` and the risk percent. Editing a rule means editing three rows.
2. **Instrument and timeframe are stored twice**: as columns and inside the JSON, with a
   Rust check (`validate_parameters`) to keep them matching.
3. **Fields nothing uses:**
   - the `risk_pct` column (0.0 on every row)
   - the `max_position_size` column ("1000")
   - the `max_units` column
   - `strategy_id` in the JSON (always null)
   - `version` in the JSON ("v1_composite" on six rows, "1" on one; only logged)

   Sizing really comes from the JSON's `sizing` block.
4. **Sizing sits in the recipe**, but it's a per-instrument choice: NAS100 runs at half
   size.
5. **An old `strategies` table exists with 0 rows** and nothing reads it. It holds the
   name we want.

## The shape

**Strategy** (new table `strategies`, replacing the empty legacy one):

| field | what |
|---|---|
| `id` | uuid |
| `name` | "Index RSI(2) dip-buy" |
| `granularity` | the timeframe it was designed for (D, M5, …); part of the recipe |
| `definition` | jsonb: `components`, `entry`, `exit`, `stop`, `max_hold_bars` |
| `notes` | plain words: where it came from, what it's for |

**Assignment** (the existing `live_strategies` table, kept):

`live_trades`, `rules`, `curator_decisions`, `kfold_validations` and suspensions all point
at `live_strategies.id`. Keeping that table as the assignment means none of them move.

| field | what |
|---|---|
| `id` | uuid (unchanged) |
| `strategy_id` | **new**, FK to `strategies` |
| `instrument_id` | already there |
| `sizing` | **new** jsonb, the `sizing` block moved out of the recipe |
| `action` | **new** jsonb, default `{"type": "oanda"}`; see phase 3 |
| `enabled`, `curator_mode` | unchanged |
| `backtest_run_id` | already there (null on every row); becomes "the backtest that justifies this assignment" |

Per-instrument parameter overrides are deliberately left out. If NAS100 needs a different
RSI threshold, that's a different strategy. Overrides make it hard to tell what is
actually running.

## Phase 1: the split, with no change in behavior

1. **Migration (Opus; you run it).**
   - Create `strategies`.
   - Add `strategy_id`, `sizing` and `action` to `live_strategies`.
   - Backfill: one strategy per distinct recipe, so today's 7 rows become 5 strategies
     (RSI(2) dip-buy, NAS100 noise-area, and the three disabled mean-reversion rows,
     which have different settings). Each row's `sizing` is copied out of its JSON.
   - The backfill is pure SQL and reversible, because `parameters` stays until phase 1
     step 4.
   Built as a **transition trigger** (`live_strategies_link_recipe`): writers still send
   `parameters`, and the trigger finds or creates the recipe and copies the sizing on every
   insert or update. Rust and Opus writers didn't change. Editing one assignment's rules
   gives it its own recipe; the others keep theirs. The trigger goes in step 4, when the
   writers move to Opus (phase 2).
2. **Rust loads the pair.** `list_for_instrument_granularity` (and the other reads in
   `repositories/live_strategies.rs`) join `strategies`, then build the same `Strategy`
   struct as today: definition + instrument + granularity + sizing. The evaluator,
   backtest and trade management don't change; they still get one `Strategy`.
3. **Parity test.** Done: Rust DB test `one_recipe_serves_many_assignments_and_reads_back_whole`,
   all Rust (263) and Opus (263) tests green, and a read-only check on prod data showing all 7
   rows rebuild identically into 5 recipes. Originally planned: For each live row, the struct built from the pair must equal the
   struct parsed from today's `parameters`. Then a replay of recent bars (the Oct 21 replay
   tool) must give the same signals.
4. **Retire the copies (needs your yes, irreversible):**
   - drop `live_strategies.parameters`, `risk_pct`, `max_position_size` and `max_units`
   - drop the old empty `strategies` table (done in step 1)
   - drop the `strategy_id`, `version`, `instrument` and `granularity` fields from the
     JSON

   Also replace the unique index on `(instrument, strategy_type, parameters)` with one on
   `(strategy_id, instrument_id)`. `strategy_type` becomes a label on the strategy, or
   goes away.

   Two things read `parameters` and must change first:
   - the pipeline stats query (`fetch_pipeline_strategy_stats`, which matches
     `strategy_configs` by parameters)
   - the create/update endpoints

## Phase 2: Opus builds and assigns

**Built 2026-10-28** (design: the "Strategy builder" canvas). What exists:

- `/strategies`: one card per recipe, filter by trading / off / drafts, rules in plain
  words, lock badge, a small chart of where it bought and sold on its first instrument,
  each instrument's switch, status and test results.
- `/strategies/:id` (one instrument): the signal chart (▲ buy, ▼ sell, time in trade
  shaded, one strip per rule lit where it was true, click a trade for its story), plain
  rules, the evidence ladder, tabs for the recipe's other instruments, "Copy" and
  "Unlock to edit".
- `/strategies/new` and `/strategies/recipes/:id/edit` (`?copy=1`): the builder. Blocks
  (`Opus.Trading.RecipeForm.catalog/0`), "all of / any of" rules, stop and hold limit, a
  live preview. Locked while anything trades; unlocking offers "edit a copy" or "switch
  it off everywhere" (refused while a trade is open). New recipes and copies save as
  drafts or go straight to the pipeline on the preview instrument (a pass adds them,
  switched off). In-place edits rewrite every assignment's `parameters` so the bridge
  trigger keeps them on the same recipe, then re-run the tests on each.
- Rust: the signal preview returns each signal's price and exit reason, and `bars`
  (OHLC + every port's true/false) for the rule strips.

Still open from the list below: choosing an instrument's size when it's switched on
(new assignments start at 1%), and an "assign to another instrument" button on a
recipe that already runs somewhere (today: run its tests on that instrument from the
builder).


- **Strategies page:** the list of recipes, each with its assignments and how each
  assignment is doing. The rules show in plain words ("Buy when RSI(2) drops below 20 and
  the price is above its 100-day average; sell when RSI(2) is back to 50 or after 10
  days").
- **Instrument page:** which strategies run on this instrument; "Assign a strategy" picks
  one, sets the size, and runs a backtest on that instrument first.
- **The backtest gate:** a new assignment can't be switched on without a passing backtest
  on its own instrument (`backtest_run_id`). The four running today are kept as they are,
  marked "no backtest on file".
- **The Strategy Editor drafts** (`strategy_drafts`) become strategies when saved. That
  gives one path from idea to recipe, with no parallel path.

## Phase 3: the strategy as a trigger

The assignment's `action` says what a signal does:

| action | who acts | example |
|---|---|---|
| `{"type": "oanda"}` | Rust trades it on OANDA, as today | NAS100 noise-area |
| `{"type": "alert_shares"}` | Opus alerts you to buy or sell on Wealthsimple | RSI(2) on SPY says buy → "Buy SPY shares" |
| `{"type": "option", "structure": "long_call", "dte": 45, "delta": 0.5}` | Opus opens it in a paper options book, then alerts you | RSI(2) on SPY says buy → open a 45-day call |

How it fits the boundaries (Rust never calls Opus):

- Rust evaluates every assignment the same way. For any action other than `oanda`, it only
  records the signal in `signal_events` and never places a trade.
- Opus picks up new signals (polling every minute, like the alert worker) and carries out
  the action. Options reuse the paper engine's leg building and management (half at
  double, stops, the 21-day close); only the entry changes from "the scan found an idea"
  to "a strategy fired".
- US stocks and ETFs have no live tick stream, so their bars arrive in batches. For them,
  Opus calls the existing `POST /api/evaluate/{granularity}` once the day's bars are
  stored, instead of relying on tick-driven evaluation.

Open questions for phase 3, to settle before building it:
- How a short signal maps to an option: a long put, or a bear call spread (needs a margin
  account).
- Whether stock signals use Questrade bars or the nightly Massive bars.

## Order of work

1. Phase 1, steps 1–3: migration, Rust loading, parity test. One PR. No visible change.
2. Phase 1, step 4: the drops, after a few days of identical live behavior and your yes.
3. Phase 2: the Opus pages and the backtest gate.
4. Phase 3: actions, starting with `alert_shares` (simplest), then `option`.
