# Codex Handoff — Engine hardening (sizing currency fix + live-path correctness)

## Goal

Fix a batch of correctness and robustness issues found in a full review of
`auro_be` (2026-06-10). All items are Rust-side, no schema migrations, no
Opus changes. One PR.

Branch: `fix/engine-hardening`.

**Already done outside this handoff (committed separately by Claude):**
the Questrade pagination fix (newest→oldest walk + typed
`AppError::BrokerHttp` variant in `error.rs`). Don't redo it; do build on
the new error variant where useful.

**Relationship to CODEX_HANDOFF_risk_module.md:** that handoff later
replaces `compute_units` with `apply_policy` and deletes the static-units
fallback branch. The fixes here are interim correctness fixes on the
*current* code; items 1 and 2 carry semantics forward into that work
(noted inline there). Do not start the risk-module work in this PR.

---

## 1. Position sizing: quote-currency → home-currency conversion (HIGHEST)

**Problem.** [sizing.rs](auro_be/src/engine/live/sizing.rs) mixes
currencies. The account is denominated in CAD, but:

- `raw_units = (equity * risk_pct) / sl_distance`
  ([sizing.rs:109](auro_be/src/engine/live/sizing.rs#L109)) treats
  `sl_distance` — which is in the instrument's **quote currency** per unit
  — as if it were CAD. USD-quoted pairs over-risk ~1.37×, GBP-quoted
  ~1.85×, JPY-quoted under-risk ~100×.
- `notional = units * entry_price`
  ([sizing.rs:134](auro_be/src/engine/live/sizing.rs#L134)) produces a
  quote-currency notional compared against CAD NAV, so the 15%-of-NAV cap
  is wrong in the inverse direction (effectively blocks all JPY-quoted
  entries).
- `check_concurrent_exposure`
  ([sizing.rs:163-198](auro_be/src/engine/live/sizing.rs#L163-L198)) sums
  the same mixed-currency notionals against the 50% cap.

This is standard fixed-fractional position sizing; the formula is
`units = risk_amount_home / (sl_distance_quote × quote→home rate)`.

**Fix.**

- Add to `sizing.rs`:
  ```rust
  /// Quote currency of an OANDA instrument ("EUR_USD" → "USD",
  /// "UK100_GBP" → "GBP"). All OANDA names are BASE_QUOTE.
  pub fn quote_currency(instrument: &str) -> Option<&str>

  /// Conversion rate from `quote` currency to `home` currency, derived
  /// from the in-memory last_quotes map:
  ///   quote == home            → 1.0
  ///   "{quote}_{home}" present → mid
  ///   "{home}_{quote}" present → 1.0 / mid
  ///   else cross via USD       → rate(quote→USD) * rate(USD→home)
  /// None when unresolvable → caller must fail closed (skip the entry).
  pub fn quote_to_home_rate(
      quotes: &HashMap<String, LastQuote>,
      quote: &str,
      home: &str,
  ) -> Option<f64>
  ```
- `SizingInput` gains `quote_to_home_rate: f64`. `compute_units` uses it:
  - `raw_units = (equity * risk_pct) / (sl_distance * rate)`
  - `notional = units * entry_price * rate`
  - record the rate in `SizingMetadata` (new field `quote_to_home_rate`).
- New `SkipReason::FxRateUnavailable` (`"fx_rate_unavailable"`). In
  `execute_entry`, resolve the rate before calling `compute_units`
  (home = account snapshot's `currency`, do NOT hardcode "CAD"); if
  `None`, return the standard `EntryRejected` report with
  `sizing_skip:fx_rate_unavailable`.
- `check_concurrent_exposure`: convert each open position's notional with
  the same helper. If a position's rate is unresolvable, fail closed
  (return `Err(SkipReason::FxRateUnavailable)`) — do not silently count
  it at face value.

**Tests** (pure, no DB): direct pair, inverse pair, USD cross, quote ==
home, unresolvable → None; `compute_units` with a JPY-style rate (~0.009)
producing ~100× more units than the uncorrected math; notional cap using
converted notional.

**Carry-forward note:** `apply_policy` in the risk-module handoff must
keep this conversion (amendment added there).

---

## 2. Skip entry when the account snapshot is missing (no unclamped fallback)

**Problem.** [evaluator.rs:509-516](auro_be/src/engine/live/evaluator.rs#L509-L516):
with `risk_pct > 0` and no NAV snapshot (first ~60s after boot, or
refresher failure), the code falls back to raw `static_units` —
bypassing policy cap, min check, 15% NAV cap, and concurrent-exposure
check.

**Fix.** Replace the fallback with an `EntryRejected` report, reason
`sizing_skip:nav_unavailable` (reuse `SkipReason::NavUnavailable`), plus
a `tracing::warn!`. Missing a signal is acceptable; trading unclamped is
not (same philosophy as `max_attempts: 1` on Oban eval jobs).

---

## 3. Order filled at OANDA but DB insert fails → untracked position (HIGH)

**Problem.** In `execute_entry`
([evaluator.rs:616-636](auro_be/src/engine/live/evaluator.rs#L616-L636))
the `live_trades` INSERT uses `?`. If it errors *after*
`create_market_order` succeeded, the error propagates out of
`evaluate_and_apply` before both the in-memory `open_positions` insert
and the delta write-back — OANDA holds an open trade Rust doesn't know
about. Next bar nothing blocks re-entry (double position), and prefill
explicitly skips OANDA trades with no `live_trades` row, so a restart
doesn't adopt it either.

**Fix.** Once the order fills, nothing may prevent the in-memory insert:

- Move the `open_positions.insert(...)` to immediately after the fill is
  parsed, **before** the DB INSERT.
- On DB INSERT failure: `tracing::error!` (include trade_id and full
  error) and continue — return the `Opened*` report as normal. Do NOT
  propagate. The DB row is audit; the journal/reconciler can repair it,
  but the in-memory map is what prevents double-entry.

Mirror in `evaluate_exit`
([evaluator.rs:801-815](auro_be/src/engine/live/evaluator.rs#L801-L815)):
if the `live_trades` UPDATE fails after `close_trade` succeeded, log the
error, still `open_positions.remove(&trade_id)`, still push the
`Closed*` report. The position is closed at OANDA; in-memory state must
reflect that regardless of audit-write success.

**Test.** Extend the existing evaluator integration-test setup: point the
state at a DB where the INSERT will fail (e.g. drop the `live_trades`
table inside the test, or insert a conflicting row) and assert the
in-memory position still exists and the report is `OpenedLong`. If clean
setup isn't possible, `#[ignore]` with a comment — do NOT invent
env-var-skip or inline-schema workarounds beyond what the existing tests
already do.

---

## 4. MAE/MFE clobbered on restart

**Problem.** Prefill resets `worst_price`/`best_price` to `entry_price`
([prefill.rs:127-128](auro_be/src/engine/live/prefill.rs#L127-L128)).
The next minor extreme then UPDATEs `mae_pct`/`mfe_pct`
([trade_management.rs:274-282](auro_be/src/engine/live/trade_management.rs#L274-L282)),
overwriting larger pre-restart values with smaller ones.

**Fix (both layers, defense in depth):**

- Prefill: add `mae_pct`, `mfe_pct` to the row returned by
  `find_open_trade_with_strategy_by_oanda_id`
  ([repositories/live_trades.rs](auro_be/src/db/repositories/live_trades.rs))
  and reconstruct extremes, direction-aware (both pcts are stored as
  non-negative magnitudes):
  - Long: `worst = entry * (1 - mae_pct)`, `best = entry * (1 + mfe_pct)`
  - Short: `worst = entry * (1 + mae_pct)`, `best = entry * (1 - mfe_pct)`
  - NULL → `entry_price` (current behavior).
- SQL guard: make the UPDATE monotonic:
  `mae_pct = GREATEST(COALESCE(mae_pct, 0), $1)`,
  `mfe_pct = GREATEST(COALESCE(mfe_pct, 0), $2)`.

**Test:** unit-test the price-reconstruction math for both directions.

---

## 5. Remove the dead Breakeven→Trailing ladder (verified dead, user-approved removal)

**Why it's dead:** every composite-era entry opens as `Trailing`
(nil-TP trend_following attaches an OANDA trailing stop on fill) or
`NotApplicable` (every other label) — see
[evaluator.rs:563-567](auro_be/src/engine/live/evaluator.rs#L563-L567).
`Initial`/`Breakeven` are only reachable via prefill of pre-composite
trades (none exist), and when reached, `fetch_take_profit` looks for a
`take_profit` param that composite configs don't have → warns every tick
and never transitions.

**Remove from [trade_management.rs](auro_be/src/engine/live/trade_management.rs):**

- `fetch_take_profit`, `fetch_strategy_type`, `fetch_trailing_k` (the
  per-tick DB queries — this also resolves the 3-queries-per-tick issue),
  `calc_be_threshold`, `calc_trailing_threshold`,
  `transition_backoff_active`, and the entire `Initial`/`Breakeven`
  match. `evaluate_trade_management` reduces to `update_mae_mfe` + an
  early return; rename/simplify as appropriate.

**Then grep-driven cleanup (delete what becomes unreferenced):**

- `OpenPosition.transition_failed_at` (and its uses in evaluator,
  prefill, tests).
- `StopLossState::initial_for_strategy_type`
  ([types.rs:399-405](auro_be/src/engine/types.rs#L399-L405)) — in
  `execute_entry` set `Trailing` when `use_trailing`, else
  `NotApplicable` directly.
- `StopLossState::Initial` / `Breakeven` enum variants IF nothing still
  references them after the above (historical
  `stop_loss_state_at_close` strings in the DB are data, not code — they
  don't block this). If something does still reference them (debug
  endpoints, backfill bins), leave the variants and note it in the PR.
- Prefill `determine_stop_loss_state`
  ([prefill.rs:306-333](auro_be/src/engine/live/prefill.rs#L306-L333)):
  trailing order present → `Trailing`; otherwise `NotApplicable` plus a
  `tracing::warn!` ("open trade {} has fixed SL but no management path").
- `OandaClient::modify_trade_stop_loss` and
  `replace_with_trailing_stop`: the ladder was likely their only caller
  (entry-time trailing uses `trailingStopLossOnFill` inside
  `create_market_order`). Grep; delete if unreferenced, including any
  test mock routes.

---

## 6. HTTP timeouts on both broker clients

reqwest `Client::new()` has **no default timeout**; a hung
`create_market_order`/`close_trade` stalls the eval task while holding
the per-instrument eval lock.

- **OandaClient** ([brokers/oanda/client.rs:19-27](auro_be/src/brokers/oanda/client.rs#L19-L27)):
  do NOT set a client-level total timeout — `pricing_stream` shares
  `http_client` and a total timeout would kill the long-lived stream.
  Instead: `Client::builder().connect_timeout(Duration::from_secs(10))`
  at construction, and a per-request
  `.timeout(Duration::from_secs(15))` on every **non-stream** request
  (small `const REQUEST_TIMEOUT` + add to each builder chain).
  `pricing_stream` gets connect_timeout only.
- **QuestradeClient** ([brokers/questrade/client.rs:59](auro_be/src/brokers/questrade/client.rs#L59)):
  no streaming; client-level
  `.timeout(Duration::from_secs(30)).connect_timeout(Duration::from_secs(10))`.

---

## 7. Reject malformed `max_position_size` instead of defaulting to 1000

[evaluator.rs:369](auro_be/src/engine/live/evaluator.rs#L369):
`static_units.parse().unwrap_or(1000)` silently trades 1000 units on a
config typo. Parse explicitly; on failure `tracing::error!` and return
`EntryRejected` with reason `sizing_skip:invalid_max_position_size`.
(The risk-module PR later replaces this branch with typed
`static_units`; this is interim correctness.)

---

## 8. Remove the `already_open` instrument-level guard (user-approved)

[evaluator.rs:199-221](auro_be/src/engine/live/evaluator.rs#L199-L221):
the instrument+granularity+strategy_type guard was deliberate for the
old per-cell TF/MR fleet and is being retired with it. Per-strategy
duplication is still prevented by the `has_position` branch in
`evaluate_strategies`, and aggregate risk by the concurrent-exposure cap.

- Delete the check and the `position_already_open` report path.
- Rework the integration test
  `evaluate_and_apply_serializes_same_key_to_single_open_position`: its
  real purpose is lock discipline. New assertions: both strategies open
  (2 `Opened*` reports total), `open_positions.len() == 2`, two open
  `live_trades` rows, no torn/partial state. Rename accordingly.

---

## 9. Light `execute_entry` cleanup (no deep restructure)

The deep sizing restructure belongs to the risk-module PR — don't
pre-empt it. In this PR only:

- Extract a `fn entry_rejected(strategy: &LiveStrategy, price: f64, reason: String) -> SignalReport`
  helper and use it for all `EntryRejected` returns (there are 3+
  near-identical blocks, plus the new ones added by items 1/2/7).
- Move the `risk_pct == 0.0` static-clamp block into a pure function in
  `sizing.rs` (e.g. `clamp_static_units(parsed: i64, policy_cap, oanda_min) -> Result<i64, SkipReason>`)
  with unit tests; `execute_entry` just maps the result.
- Replace the `std::io::Error::other` hack
  ([evaluator.rs:361-366](auro_be/src/engine/live/evaluator.rs#L361-L366))
  with a normal logged `EntryRejected` (missing instrument metadata is a
  skip, not a process error).

---

## Tests / acceptance

- `cargo check` and `cargo test --lib` pass; DB-backed tests follow the
  existing `#[ignore] = "requires AURO_TEST_DATABASE_URL"` pattern (see
  prefill tests). No env-var silent-skip in new tests, no inline schema
  beyond what existing tests already do, no custom log capture.
- Grep proves: no remaining references to `fetch_take_profit`,
  `transition_failed_at`, `initial_for_strategy_type`,
  `position_already_open`.
- Sizing unit tests cover the JPY-style and GBP-style conversion cases
  and the fail-closed paths (`fx_rate_unavailable`, `nav_unavailable`).

## Out of scope

- Risk-module / `apply_policy` work (separate handoff).
- `pnl_percent → pnl_pct` rename (folds into journal-enrichment PR).
- Order idempotency via OANDA `clientExtensions` (future; timeouts +
  reconciler are the interim mitigation).
- Questrade pagination (already fixed).
