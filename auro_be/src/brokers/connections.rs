//! The outside connections the live engine can change while running, and
//! what Opus's Settings page shows about each: in use since when, the last
//! check and whether a restart is needed to switch accounts.
//!
//! The OANDA key lives in `OandaClient` (shared by its clones); Massive is
//! replaceable here. `api::settings` applies a saved change.

use std::collections::BTreeMap;
use std::sync::RwLock;

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::brokers::massive::client::MassiveClient;

/// Connection names, as Opus's Settings page calls them.
pub const OANDA: &str = "oanda";
pub const MASSIVE: &str = "massive";

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ConnectionStatus {
    /// Since when the current values have been in use; none when the
    /// connection isn't set up.
    pub in_use_since: Option<DateTime<Utc>>,
    pub checked_at: Option<DateTime<Utc>>,
    /// The last check: none before any.
    pub ok: Option<bool>,
    /// The last check's answer in plain words.
    pub words: Option<String>,
    /// Saved values name another account or address than the one running:
    /// they apply after a restart.
    pub restart_to_switch: bool,
}

#[derive(Default)]
pub struct Connections {
    massive: RwLock<Option<MassiveClient>>,
    status: RwLock<BTreeMap<&'static str, ConnectionStatus>>,
}

impl Connections {
    pub fn new(massive: Option<MassiveClient>) -> Self {
        Self {
            massive: RwLock::new(massive),
            status: RwLock::default(),
        }
    }

    /// The Massive client in use, if one is configured.
    pub fn massive(&self) -> Option<MassiveClient> {
        self.massive
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn set_massive(&self, client: MassiveClient) {
        *self
            .massive
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(client);
    }

    /// Every connection's status, by name.
    pub fn statuses(&self) -> BTreeMap<&'static str, ConnectionStatus> {
        self.status
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn status(&self, name: &'static str) -> ConnectionStatus {
        self.statuses().remove(name).unwrap_or_default()
    }

    /// Change `name`'s status in place.
    pub fn update(&self, name: &'static str, change: impl FnOnce(&mut ConnectionStatus)) {
        let mut all = self
            .status
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        change(all.entry(name).or_default());
    }

    /// Record a check's outcome at `at`. A passing check that put new
    /// values in use (`started`) restarts the "in use since" clock.
    pub fn record_check(
        &self,
        name: &'static str,
        at: DateTime<Utc>,
        ok: bool,
        words: String,
        started: bool,
    ) {
        self.update(name, |status| {
            status.checked_at = Some(at);
            status.ok = Some(ok);
            status.words = Some(words);
            if started || (ok && status.in_use_since.is_none()) {
                status.in_use_since = Some(at);
            }
        });
    }
}
