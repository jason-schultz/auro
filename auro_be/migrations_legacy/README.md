# Legacy sqlx migrations (frozen 2026-10-17)

Opus owns every database migration now; see
`opus/priv/repo/migrations/20261017130000_adopt_rust_schema.exs`, which
restates this schema idempotently. Auro no longer runs migrations at startup
(it only verifies the tables it needs exist: `src/db/schema_check.rs`).

These files are kept as history of how the Rust-owned tables came to be.
Do not add to them; put new changes in Opus.
