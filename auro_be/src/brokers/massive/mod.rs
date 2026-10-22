//! Massive (formerly Polygon.io): US equity bars for the stock universe.
//!
//! A data vendor, not a broker — no accounts, no orders. It lives beside the
//! broker clients because it feeds the same `candles` table through the same
//! persist path as Questrade.

pub mod client;
pub mod models;
