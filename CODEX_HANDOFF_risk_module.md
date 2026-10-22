# Codex Handoff — Opus.Trading.Risk (centralize risk policy, push to Rust)

## Goal

Move the "what size should this trade be?" decision out of Rust and into
Opus. Opus computes a `RiskPolicy` per strategy from DB state, persists it
to a `risk_policies` table, and pushes the full policy set to Rust as a
versioned idempotent snapshot. Rust caches the policies in memory and
applies them at entry time against its own real-time portfolio state
(NAV, open positions, ATR-derived SL distance).

This establishes the foundation for portfolio-level risk (concurrent
exposure caps, sector concentration, account drawdown ceilings) — all of
which will extend this module with additional policy fields, no new
infrastructure required.

## Why (architecture)

**Opus is the brain, Rust is the executor.** This split is a deliberate
design choice for the project. Opus authors risk *rules* from its
DB-of-record view. Rust *applies* those rules using its real-time
in-memory state at the moment of decision.

This separation gives us:

- **Policy lives where reasoning lives.** Opus computes from full DB
  context (all strategies, all positions, all historical PnL). Rust
  doesn't need to load or reason about that — it gets the rules ready
  to apply.
- **State lives where state is fresh.** Rust holds current NAV, open
  positions, intraday exposure in memory. Trading decisions at the
  microsecond don't need to wait on an Opus roundtrip. Same-bar
  concurrent signals (e.g. CORN/SOYBN paired entries) resolve locally.
- **One service can be down without breaking the other.** If Opus is
  unreachable, Rust keeps trading on its last-pushed policy. If Rust is
  restarting, Opus keeps recomputing policies; Rust picks up the latest
  on bootstrap.

### Policy is a budget, not a calculation

Critical framing: the policy Opus pushes is a **set of limits and
parameters**, not a precomputed answer. Examples:

- "risk 1% per trade" (parameter)
- "max units per strategy: 50000" (limit)
- "max NAV concurrent exposure: 30%" (portfolio limit — future)
- "max sector concentration: 15%" (portfolio limit — future)
- "halve sizing if intraday account drawdown < -5%" (state-dependent rule)

Rust evaluates each limit against its current portfolio state at trade
time. Two strategies firing on the same bar both consult the same policy
budget; Rust serializes their applications locally so the second one
sees the first's consumption.

This is what lets us preserve "Opus owns policy" while solving the
concurrent-signal problem: Opus doesn't *make* the same-bar decision,
it sets the *rules* by which Rust makes it.

### Why push, not pull or shared-table

We're standardizing on **versioned idempotent push** (HTTP) for
Opus → Rust state updates. The full design:

- Opus writes new policy to `risk_policies` table (audit/source-of-truth)
- Opus pushes the full versioned snapshot to Rust over HTTP
- Rust validates version is newer than its cached version, atomically
  replaces its cache
- Opus retries the push on failure with the *same* payload (same version)
- Periodic safety push catches any silent push failures

This is the same pattern as Rules, intentionally. Standardizing on one
pattern reduces cognitive load. The pattern is also intentionally close
to what Kafka/RabbitMQ deliver in larger systems, so it's good
preparation for that step if Auro ever needs it.

Alternative considered: DB-as-truth with LISTEN/NOTIFY. Rejected for
this PR because the push pattern is already established, gives us
explicit service contracts, and the idempotency discipline is more
valuable as a pattern to internalize than the marginal correctness gain
from LISTEN/NOTIFY's recovery semantics.

## Idempotency contract (READ THIS)

Push must be **idempotent**: applying the same payload N times yields
the same Rust state. This is enforced by five mechanisms, **all
required**:

1. **Versioned payload.** Every push carries a monotonic `version`
   (`bigint`, strictly increasing per Opus compute cycle). Rust
   compares incoming `version` to its cached `version`; if incoming
   `<= cached`, **reject silently with a log line**. This makes
   duplicates safe and out-of-order delivery safe.

2. **Full snapshot, never deltas.** Every push contains the complete
   policy set for *all* live_strategies. No "send only changes"
   optimization, ever. Applying the snapshot replaces all cached
   policies. This is the property that lets `apply N times = apply once`.

3. **Atomic cache swap on Rust.** When a valid push arrives, Rust
   replaces its entire policy cache in a single write under the
   `RwLock` write guard. No per-strategy upserts. Concurrent readers
   see either the full old cache or the full new cache, never a mix.

4. **Retry-safe on Opus.** Opus retries failed pushes (non-2xx, network
   error, timeout) with the *same payload* including the *same version*.
   Cap at N retries (5 with exponential backoff: 100ms, 500ms, 2s, 10s,
   30s), then log alert and surface to ops. Because the payload is
   versioned and full-snapshot, retries can't corrupt Rust state.

5. **Bootstrap version reconciliation.** Rust's startup `GET
   /api/risk/policies` returns `{ version, policies }`. Rust sets its
   initial cache version from the response. The next push with a
   higher version applies; a push with `<= bootstrap_version` is
   rejected (e.g. if Opus restarted and re-pushed an earlier version).
   No race between bootstrap and the first push.

## Schema

New Ecto migration: `create_risk_policies_table.exs`.

```elixir
create table(:risk_policies, primary_key: false) do
  add :live_strategy_id,
      references(:live_strategies, type: :binary_id, on_delete: :delete_all),
      primary_key: true,
      null: false

  add :sizing_mode, :string, size: 16, null: false  # "dynamic" | "static" | "off"
  add :risk_pct, :float                              # null unless sizing_mode = "dynamic"
  add :max_units, :bigint                            # per-strategy unit cap, nullable
  add :instrument_policy_cap, :bigint                # per-instrument unit cap, nullable
  add :static_units, :bigint                         # for sizing_mode = "static", nullable
  add :config_incomplete_reasons, {:array, :string}, default: []
  add :computed_at, :utc_datetime_usec, null: false

  timestamps(type: :utc_datetime_usec)
end

# Global version table (single row) — increments on every policy recompute
create table(:risk_policy_versions, primary_key: false) do
  add :id, :integer, primary_key: true, default: 1  # enforced to always be 1
  add :version, :bigint, null: false, default: 0
  add :computed_at, :utc_datetime_usec, null: false
end

create constraint(:risk_policy_versions, :singleton, check: "id = 1")
```

Upsert pattern matches `rules` table. One row per strategy in
`risk_policies` (latest state). The single-row `risk_policy_versions`
table is the source of the monotonic `version` field; Opus increments
it transactionally on every recompute.

## Module layout

```
opus/lib/opus/trading/
  risk_engine.ex             # Opus.Trading.RiskEngine (GenServer)
  risk/
    builder.ex               # Opus.Trading.Risk.Builder (pure compute)
    policy.ex                # Opus.Trading.Risk.Policy (Ecto schema)

opus/lib/opus/trading/strategy_config/
  validator.ex               # Opus.Trading.StrategyConfig.Validator
                             # (config-completeness checks; M5 TF guard
                             # moves here, NOT into the risk module —
                             # config validation is a precondition,
                             # not a risk decision)

opus/test/opus/trading/
  risk_engine_test.exs
  risk/
    builder_test.exs
  strategy_config/
    validator_test.exs
```

**Key constraint: `Builder.build_policy/2` is a pure function.** No
Repo calls, no DB access. It takes the strategy struct and a caps map
as inputs and returns a `%RiskPolicy{}`. The DB reads happen in
`compute_policies/0` (the orchestrator). This is **required for the
future backtest integration** — backtest needs to call `build_policy`
in a tight loop with synthetic inputs, without touching the DB.

**New files:**

- `opus/lib/opus/trading/risk_engine.ex` — `Opus.Trading.RiskEngine`
  GenServer: periodic safety push + imperative `republish/0` +
  version increment on each cycle
- `opus/lib/opus/trading/risk/builder.ex` — pure functions:
  `compute_policies/0` (does DB reads, calls `build_policy` per row),
  `build_policy/2` (pure), `sizing_mode_for/1` (pure)
- `opus/lib/opus/trading/risk/policy.ex` — Ecto schema + changeset
- `opus/lib/opus/trading/strategy_config/validator.ex` — pure
  `validate/1` returning `:ok | {:incomplete, [reasons]}`. M5 TF
  config-completeness logic lives here.
- Migrations as above

**Modified Opus files:**

- `opus/lib/opus/application.ex` — add `RiskEngine` to supervision tree
  (after `RulesEngine`)
- `opus/lib/opus/auro/client.ex` — add `push_risk_policies/1` HTTP call
  with retry logic (existing retry helper if present)
- `opus/lib/opus/trading/strategy_curator.ex` — call
  `RiskEngine.republish/0` after promote/demote
- Any LiveStrategy CRUD callsite (deploys, manual creation, deletion) —
  call `RiskEngine.republish/0` after mutation
- `opus_web/router.ex` — add `GET /api/risk/policies` route
- `opus_web/controllers/risk_controller.ex` — new controller, single
  action: `index/2` returns `{version, policies}` snapshot

## Risk module behavior

### `Opus.Trading.Risk.Builder.compute_policies/0`

Returns `{version, [%RiskPolicy{}, ...]}`. Logic:

1. Begin transaction
2. Increment `risk_policy_versions.version`, return new value
3. Load all `live_strategies` rows (regardless of `enabled` — Rust
   needs every policy in case rules engine flips state)
4. Load all `instrument_unit_caps` into a map
5. For each strategy, call `build_policy(strategy, caps_map)` (pure)
6. Upsert all policies into `risk_policies` table (full replacement
   via `Repo.insert_all` + `on_conflict: {:replace, [...]}`)
7. Commit transaction
8. Return `{version, policies}`

### `Opus.Trading.Risk.Builder.build_policy/2` (PURE)

```
sizing_mode is :off if:
  - StrategyConfig.Validator.validate(strategy) returns {:incomplete, _}
  - OR strategy.risk_pct in (nil, 0) AND strategy.max_position_size is nil

sizing_mode is :dynamic if:
  - validator OK AND strategy.risk_pct > 0

sizing_mode is :static if:
  - validator OK AND strategy.risk_pct in (nil, 0) AND
    strategy.max_position_size is set
```

If `:off` due to incomplete config, `config_incomplete_reasons` is the
list returned by `Validator.validate/1`. All numeric fields nil. Rust
will see "off" and skip with the reasons surfaced in SignalReport.

### `Opus.Trading.StrategyConfig.Validator.validate/1`

Pure function. Returns `:ok | {:incomplete, [String.t()]}`.

Current rule (the M5 TF check that lives in
[evaluator.rs:reject_incomplete_m5_tf_config](auro_be/src/engine/live/evaluator.rs)
today):

- If `strategy.granularity == "M5"` AND
  `strategy.strategy_type == "trend_following"`, require:
  - `risk_pct > 0`
  - `max_units` set
  - `parameters["confirm_bars"]` set
  - `parameters["trailing_k"]` set

Each missing field appended to the reasons list. Returns
`{:incomplete, reasons}` if any missing, `:ok` otherwise. The Rust
function `reject_incomplete_m5_tf_config` gets deleted.

This module is separate from Risk because **config validity is a
precondition for any policy decision, not a sizing decision itself**.
Future validators (parameter ranges, asset compatibility, etc.) belong
here too.

### `Opus.Trading.Risk.Builder.persist_and_push/1`

1. Call `compute_policies/0` → `{version, policies}`
2. Build push payload (see below)
3. Call `Opus.Auro.Client.push_risk_policies/1` (with retry logic)
4. Log cycle: `[RiskEngine] cycle N (version V): pushed=X (dyn=A, sta=B, off=C)`

## RiskEngine GenServer

Same pattern as RulesEngine:

- Polling interval: 5 minutes (safety push; primary trigger is imperative)
- Initial delay: 30 seconds
- `init/1` schedules first cycle, computes initial policies, pushes
- `handle_info(:poll, ...)` runs `run_cycle/1`
- Public `republish/0` for imperative invocation (called by curator,
  CRUD endpoints)
- Crash → supervised restart; on restart, compute fresh policy from DB
  (version continues from `risk_policy_versions` row, monotonic
  across restarts)

## Push protocol

### `Opus.Auro.Client.push_risk_policies/1`

POST `http://<auro>/api/risk/policies` with body:

```json
{
  "version": 17,
  "computed_at": "2026-05-26T...Z",
  "policies": [
    {
      "live_strategy_id": "uuid",
      "sizing_mode": "dynamic",
      "risk_pct": 0.01,
      "max_units": null,
      "instrument_policy_cap": 1000,
      "static_units": null,
      "config_incomplete_reasons": []
    },
    {
      "live_strategy_id": "uuid",
      "sizing_mode": "off",
      "risk_pct": null,
      "max_units": null,
      "instrument_policy_cap": null,
      "static_units": null,
      "config_incomplete_reasons": [
        "risk_pct must be > 0",
        "parameters.confirm_bars missing"
      ]
    }
  ]
}
```

Expected response: `200 OK` with `{ "received": N, "version": V }`.
Any other status triggers retry per idempotency contract above. Log
warnings on retry; alert on retry-exhausted.

### `GET /api/risk/policies` (Opus → Rust bootstrap)

Returns the same payload shape (no retry semantics needed — Rust calls
once at startup; failure means empty cache + all-trades-skip).

### Rust receive handler

`POST /api/risk/policies` on Rust:

1. Parse body, validate shape (400 on malformed)
2. Acquire write lock on cache state
3. If `payload.version <= cache.version`, log "stale push rejected
   (incoming=V_in, current=V_cur)" and return 200 (idempotent — not
   an error condition)
4. Else, replace `cache.policies` and `cache.version` atomically
5. Log `[RiskPolicies] applied version V (N policies, dyn=A, sta=B, off=C)`
6. Return `200 OK` with `{ "received": N, "version": V }`

## Rust changes

### Add

- `auro_be/src/api/risk.rs` — new module:
  - `POST /api/risk/policies` handler
  - Cache type: `Arc<RwLock<RiskPolicyCache>>` on `AppState.live`
    where `RiskPolicyCache { version: i64, policies: HashMap<Uuid, RiskPolicy> }`
- `auro_be/src/engine/live/risk_policy.rs` — new struct:
  ```rust
  pub enum SizingMode { Dynamic, Static, Off }

  pub struct RiskPolicy {
      pub live_strategy_id: Uuid,
      pub sizing_mode: SizingMode,
      pub risk_pct: Option<f64>,
      pub max_units: Option<i64>,
      pub instrument_policy_cap: Option<i64>,
      pub static_units: Option<i64>,
      pub config_incomplete_reasons: Vec<String>,
  }
  ```
- `auro_be/src/clients/opus.rs` — HTTP client for bootstrap
  `GET /api/risk/policies` on startup. Logs how many policies and the
  bootstrapped version on success.
- `auro_be/src/engine/live/sizing.rs` — `apply_policy` function:
  ```rust
  pub fn apply_policy(
      policy: &RiskPolicy,
      runtime: SizingRuntime,
      portfolio: &PortfolioState,
  ) -> SizingDecision
  ```
  - Match on `policy.sizing_mode`
  - `Off` → skip with first `config_incomplete_reason` or "sizing_off"
  - `Dynamic` → compute `(nav * risk_pct) / (sl_distance * quote_to_home_rate)`,
    clamp by `max_units`, `instrument_policy_cap`, instrument min/max from
    `SizingRuntime`. **MUST preserve the quote-currency → home-currency
    conversion introduced in CODEX_HANDOFF_engine_hardening.md** (the
    `quote_to_home_rate` helper and `SkipReason::FxRateUnavailable`
    fail-closed path carry over into `apply_policy` unchanged; notional
    caps also use converted notionals).
  - `Static` → use `static_units`, clamp same way
  - Returns existing `SizingDecision` enum (`Place | Skip`)
- `auro_be/src/engine/live/portfolio_state.rs` — new struct tracking
  current concurrent exposure, open positions per sector, etc. Reads
  from existing in-memory open-position state. This is the snapshot
  passed to `apply_policy`. For this PR, only the open-position list
  is needed (concurrent exposure caps are next PR), but the struct
  exists so the policy contract is forward-compatible.

### Concurrency requirement (critical)

`apply_policy` is called from the entry path which may have multiple
concurrent invocations (same-bar paired signals, e.g. CORN/SOYBN).
To prevent over-allocation against a portfolio budget:

- Wrap the entry-decision critical section in a `tokio::sync::Mutex`
  guard on `PortfolioState`. The lock spans "build snapshot → call
  apply_policy → if Place, reserve exposure → release."
- Reservation is optimistic: increment local exposure counter
  immediately; the actual OANDA order is async and follows. If the
  order fails, decrement on failure.
- For this PR (no portfolio caps yet), the mutex still exists and is
  taken, but the only thing inside the critical section is the
  `apply_policy` call — no concurrent invariants to protect yet. This
  lets next PR add concurrent-exposure logic without re-architecting
  the lock.

Document this in a comment block at the top of
`auro_be/src/engine/live/portfolio_state.rs`.

### Replace

In [auro_be/src/engine/live/evaluator.rs::execute_entry](auro_be/src/engine/live/evaluator.rs):

OLD:
```rust
let strategy_max_units = strategy.max_units;
let risk_pct = strategy.risk_pct;
// ... branch on risk_pct == 0 ...
let decision = compute_units(SizingInput { ... });
```

NEW:
```rust
let policy = {
    let cache = state.live.risk_policy_cache.read().await;
    cache.policies.get(&strategy.id).cloned()
};
let Some(policy) = policy else {
    return Ok(Some(skip_report(strategy, "no_risk_policy")));
};
// Critical section for same-bar concurrent applications
let decision = {
    let mut portfolio = state.live.portfolio_state.lock().await;
    let snapshot = portfolio.snapshot();
    let d = apply_policy(&policy, runtime, &snapshot);
    if matches!(d, SizingDecision::Place(_)) {
        portfolio.reserve(/* sized exposure */);
    }
    d
};
```

### Remove

- `LiveStrategy.risk_pct` field ([types.rs:374](auro_be/src/engine/types.rs#L374))
- `LiveStrategy.max_units` field ([types.rs:375](auro_be/src/engine/types.rs#L375))
- `risk_pct, max_units` columns from all SELECT statements in
  [repositories/live_strategies.rs](auro_be/src/db/repositories/live_strategies.rs)
- `risk_pct, max_units` from INSERT statements at
  [evaluator.rs:1173, 1189](auro_be/src/engine/live/evaluator.rs)
- `instrument_unit_caps` query and load in
  [auro_be/src/engine/live/instrument_cache.rs:38-39](auro_be/src/engine/live/instrument_cache.rs#L38)
  (Rust no longer reads this table)
- `InstrumentMeta.policy_max_units` field
- `SizingInput.strategy_max_units` and `SizingInput.instrument_policy_max_units`
  fields
- Old `compute_units` function (replaced by `apply_policy`)
- Static-fallback branch (`if risk_pct == 0.0`) in
  [evaluator.rs:540](auro_be/src/engine/live/evaluator.rs#L540)
- `reject_incomplete_m5_tf_config` function (logic moved to
  `Opus.Trading.StrategyConfig.Validator`)

### Keep

- `InstrumentMeta.min_trade_size`, `max_trade_size`, `trade_units_precision`
  (OANDA execution constraints, not policy)
- ATR + SL distance math
- NAV from OANDA stream
- All trade-management code

## Deploy strategy

This PR is structurally backward-incompatible: any unmigrated Rust
process pointing at this Opus will skip all entries with
`no_risk_policy`; any unmigrated Opus pointing at this Rust will not
populate the cache. Deploy must be sequenced.

**Sequence:**

1. **Phase 1 (additive Opus deploy).** Opus ships with the new module,
   table, migrations, push code — but `live_strategies.risk_pct` and
   `.max_units` columns *stay populated* by existing CRUD paths. Opus
   starts pushing policies. Old Rust ignores them (no handler yet).
   Verify: `risk_policies` table populating, `[RiskEngine]` log lines
   appearing, no behavioral change on Rust side.

2. **Phase 2 (Rust switch deploy).** Rust ships with the new
   `apply_policy` code path, bootstrap GET, push receiver, removal of
   old `compute_units`. Rust startup logs
   `[RiskPolicies] bootstrap: loaded N policies (version V)`. First
   live entry uses policy. Verify: `SELECT * FROM risk_policies`
   matches what Rust applies (sample a few signal reports).

3. **Phase 3 (cleanup, future).** Once stable, the
   `live_strategies.risk_pct` and `.max_units` columns become unused
   except as inputs to Opus's policy compute. A later PR may move
   them out of `live_strategies` into a `strategy_sizing_config`
   table for clarity, but this is NOT in scope.

**Rollback path:** if phase 2 misbehaves, revert Rust deploy; Opus's
phase 1 changes are inert without the Rust counterpart.

## Tests

### Opus side

`opus/test/opus/trading/risk/builder_test.exs` — pure function tests
for `build_policy/2`:
- Dynamic mode (risk_pct > 0)
- Static mode (risk_pct = 0, max_position_size set)
- Off mode (both nil/0)
- M5 TF complete config → dynamic
- M5 TF missing each required field → off with correct reasons
- With/without `instrument_policy_cap`
- All variants must be testable with synthetic input only (no DB) —
  this validates the pure-function constraint.

`opus/test/opus/trading/strategy_config/validator_test.exs`:
- Each missing M5 TF field surfaces in the reasons list
- Non-M5 / non-TF strategies always return `:ok`
- All edge combinations

`opus/test/opus/trading/risk_engine_test.exs`:
- `republish/0` triggers compute + persist + push + version increment
- Periodic poll fires after interval
- Push failure logged, retried, eventually surfaces alert
- Crash + restart resumes from latest DB version (no version rollback)

`opus/test/opus_web/controllers/risk_controller_test.exs`:
- `GET /api/risk/policies` returns `{version, policies}` in expected shape
- Empty state returns `{version: 0, policies: []}`

### Rust side

`apply_policy` unit tests:
- Dynamic mode computes correctly, applies all clamps
- Static mode uses static_units
- Off mode skips with first reason
- Below minimum skips with "below_min"
- All clamps respected in correct order

Push receive endpoint:
- Valid payload with higher version → cache replaced, 200
- Valid payload with equal/lower version → cache untouched, 200, log line
- Malformed payload → 400
- Concurrent push + read → reader sees either old or new full snapshot

Bootstrap GET (mocked Opus response):
- Successful response populates cache + sets version
- 5xx/timeout → cache empty, version=0, entries skip with no_risk_policy
- Subsequent push with version > bootstrap_version applies normally

Concurrency:
- Two simultaneous `apply_policy` calls serialize through the
  `PortfolioState` mutex
- (Forward-looking) Concurrent calls don't double-allocate against
  a shared exposure budget

Per [feedback_codex_test_workarounds.md](memory): standard test patterns
only, mark `#[ignore]` or `@tag :pending` if infra setup is fragile.

## Acceptance criteria

- All new and existing tests pass: `cargo test --lib`, `mix test`.
- Migrations apply cleanly and are reversible.
- After phase 1 deploy: `risk_policies` table populated, Opus log shows
  `[RiskEngine] cycle 1 (version 1): pushed=N`.
- After phase 2 deploy: Rust startup logs
  `[RiskPolicies] bootstrap: loaded N policies (version V)`. First live
  entry uses policy. SignalReport metadata shows which clamps applied.
- Idempotency manually verified: replay a captured push payload twice
  via curl, Rust accepts first, rejects second (log line shows
  "stale push rejected").
- Concurrent same-bar entry verified: trigger CORN + SOYBN simultaneously,
  both apply policy (no over-allocation, no missed evaluation).

## Out of scope

- **Portfolio-aware policy fields** (concurrent exposure cap, sector
  concentration, drawdown tiering). Policy struct designed to be
  forward-compatible (`PortfolioState` snapshot already passed into
  `apply_policy`), but no new fields populated yet. Next PR.

- **Backtest integration.** Backtest currently doesn't size; it
  computes `pnl_percent`. After this PR ships, the immediate next step
  is to make the backtest harness call `Builder.build_policy/2` (pure,
  no DB) for every simulated trade. The pure-function constraint in
  this PR is **specifically** to keep that path open. Backtest PR will:
  (1) call `build_policy` from Rust backtest via an Elixir wrapper or
  via a duplicated-and-tested port, (2) extend to portfolio-aware
  backtest (multi-strategy shared NAV + open-position state), (3)
  re-point k-fold / walk-forward to score *sized* PnL. See
  [[backlog-portfolio-risk]] for sequencing.

- **Migrating Rules to the same idempotency contract.** Rules' push
  doesn't currently carry a version field. Worth a follow-up PR to
  bring Rules under the same idempotency discipline, but not part of
  this scope.

- **Migrating Rules' bootstrap to HTTP-pull from Opus.** Currently
  Rust reads the `rules` table directly at startup
  ([prefill.rs](auro_be/src/engine/live/prefill.rs)). Same code smell
  this PR fixes for risk; worth a small follow-up.

- **Cross-validation of the sizing formula against published
  practitioner methodology.** Defaults (1% risk_pct, formula
  `(nav * risk_pct) / sl_distance_pct`) come from
  [[decision-dynamic-position-sizing]] but have not been validated
  against published quant risk literature
  (e.g. Kelly fraction, vol-targeted sizing, ATR-multiple SL). Worth a
  dedicated research session — capture findings in
  [[auro-reference-library]] when done. Not blocking this PR; the
  formula is configurable per strategy so changes are parameter
  tweaks, not architectural.

- **Removing `live_strategies.risk_pct` / `.max_units` columns.** Keep
  them as inputs to Opus's policy compute for now. Future cleanup may
  move them into a `strategy_sizing_config` table.

## Notes

- Branch: `feat/opus-trading-risk`. PR, not direct to main.
- Net diff likely negative LOC despite the new module: Opus side adds
  ~400 LOC (module + tests + migration), Rust side removes ~250 LOC of
  sizing branching plus adds ~150 LOC of cleaner `apply_policy`.
- Per [decision_universe_vs_enabled.md](memory): compute policies for
  ALL `live_strategies` rows, not just enabled. Rust needs the policy
  in cache even for disabled strategies in case rules engine flips
  state mid-cycle.
- Per [feedback_proper_fixes_not_stopgaps.md](memory): this IS the
  proper fix for the scattered risk-decision problem. Earlier ad-hoc
  fixes (CORN/SOYBN trivial-TP, "all strategies risk_pct=0") are
  symptoms of the architectural problem this PR addresses.
- The idempotency pattern (versioned full-snapshot push, retry-safe,
  bootstrap-reconciled) is intentionally close to Kafka/RabbitMQ
  message semantics. If Auro ever needs durable message infrastructure,
  this pattern ports forward — only the transport changes.
- Once this lands, the immediate next PRs in priority order:
  1. Backtest integration of `build_policy` (validates the whole
     architecture in simulation)
  2. Portfolio-aware policy fields (concurrent exposure, sector caps)
  3. Rules idempotency parity
