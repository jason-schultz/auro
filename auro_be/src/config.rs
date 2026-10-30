use std::env;

/// Which of the two processes this is. Same crate, two binaries: `auro`
/// trades, `auro-tester` runs the backtests and pipeline stages so that
/// testing never takes CPU, runtime or pool time from live trading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// OANDA stream, candle feed, evaluator, trade management, live-state API.
    Live,
    /// Backtest, pipeline and report endpoints only. No OANDA, Questrade or
    /// Massive connection and no background jobs.
    Tester,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Live => "live",
            Mode::Tester => "tester",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub mode: Mode,
    pub database_url: String,
    /// Postgres connections this process may hold. Live is small (its
    /// queries are short); the tester's is larger (backtests load years of
    /// bars at once). `AURO_LIVE_DB_POOL_SIZE` / `AURO_TESTER_DB_POOL_SIZE`.
    pub db_pool_size: u32,
    /// OANDA settings. Required live; the tester never calls OANDA, so they
    /// may be absent there (empty strings).
    pub oanda_api_key: String,
    pub oanda_account_id: String,
    pub oanda_base_url: String,
    pub oanda_stream_url: String,
    pub host: String,
    /// Live: `PORT` (default 3000). Tester: `AURO_TESTER_PORT` (default
    /// 3001) — never `PORT`, which `.env` sets for the live engine.
    pub port: u16,
    /// Initial Questrade refresh token. Only needed on first run to seed the DB.
    /// After that the DB row rotates automatically and this env var is ignored.
    pub questrade_refresh_token: Option<String>,
    /// Massive (Polygon) market data. Absent key = US stock bars disabled.
    pub massive_api_key: Option<String>,
    pub massive_base_url: String,
    /// Plan rate limit; 5 on the free plan, 0 = unlimited (paid plans).
    pub massive_calls_per_minute: u32,
}

const DEFAULT_LIVE_PORT: u16 = 3000;
const DEFAULT_TESTER_PORT: u16 = 3001;
const DEFAULT_LIVE_DB_POOL: u32 = 5;
const DEFAULT_TESTER_DB_POOL: u32 = 10;

impl Config {
    pub fn from_env(mode: Mode) -> anyhow::Result<Self> {
        Self::from_lookup(mode, |key| env::var(key).ok())
    }

    fn from_lookup(mode: Mode, get: impl Fn(&str) -> Option<String>) -> anyhow::Result<Self> {
        let required = |key: &str| {
            get(key).ok_or_else(|| {
                anyhow::anyhow!("{key} is not set (the {} engine needs it)", mode.as_str())
            })
        };
        let oanda = |key: &str| match mode {
            Mode::Live => required(key),
            Mode::Tester => Ok(get(key).unwrap_or_default()),
        };
        let (port_var, default_port, pool_var, default_pool) = match mode {
            Mode::Live => (
                "PORT",
                DEFAULT_LIVE_PORT,
                "AURO_LIVE_DB_POOL_SIZE",
                DEFAULT_LIVE_DB_POOL,
            ),
            Mode::Tester => (
                "AURO_TESTER_PORT",
                DEFAULT_TESTER_PORT,
                "AURO_TESTER_DB_POOL_SIZE",
                DEFAULT_TESTER_DB_POOL,
            ),
        };

        Ok(Self {
            mode,
            database_url: required("DATABASE_URL")?,
            db_pool_size: match get(pool_var) {
                Some(v) => v
                    .parse()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| anyhow::anyhow!("{pool_var} must be a positive number"))?,
                None => default_pool,
            },
            oanda_api_key: oanda("OANDA_API_KEY")?,
            oanda_account_id: oanda("OANDA_ACCOUNT_ID")?,
            oanda_base_url: oanda("OANDA_BASE_URL")?,
            oanda_stream_url: oanda("OANDA_STREAM_URL")?,
            host: get("HOST").unwrap_or_else(|| "127.0.0.1".to_string()),
            questrade_refresh_token: get("QUESTRADE_REFRESH_TOKEN"),
            massive_api_key: get("MASSIVE_API_KEY").filter(|k| !k.is_empty()),
            massive_base_url: get("MASSIVE_BASE_URL")
                .unwrap_or_else(|| "https://api.massive.com".to_string()),
            massive_calls_per_minute: get("MASSIVE_CALLS_PER_MINUTE")
                .and_then(|v| v.parse().ok())
                .unwrap_or(5),
            port: match get(port_var) {
                Some(v) => v
                    .parse()
                    .map_err(|e| anyhow::anyhow!("{port_var} must be a valid port number: {e}"))?,
                None => default_port,
            },
        })
    }

    pub fn listen_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |key| map.get(key).cloned()
    }

    const LIVE_ENV: &[(&str, &str)] = &[
        ("DATABASE_URL", "postgres://x"),
        ("OANDA_API_KEY", "k"),
        ("OANDA_ACCOUNT_ID", "a"),
        ("OANDA_BASE_URL", "https://api"),
        ("OANDA_STREAM_URL", "https://stream"),
        ("PORT", "3000"),
    ];

    #[test]
    fn tester_starts_without_oanda_settings() {
        let config =
            Config::from_lookup(Mode::Tester, lookup(&[("DATABASE_URL", "postgres://x")])).unwrap();

        assert_eq!(config.mode, Mode::Tester);
        assert_eq!(config.port, 3001);
        assert_eq!(config.db_pool_size, 10);
        assert!(config.oanda_api_key.is_empty());
    }

    #[test]
    fn tester_ignores_the_live_port() {
        // `.env` sets PORT=3000 for the live engine; the tester must not take it.
        let config = Config::from_lookup(Mode::Tester, lookup(LIVE_ENV)).unwrap();
        assert_eq!(config.port, 3001);

        let mut env = LIVE_ENV.to_vec();
        env.push(("AURO_TESTER_PORT", "3101"));
        env.push(("AURO_TESTER_DB_POOL_SIZE", "24"));
        let config = Config::from_lookup(Mode::Tester, lookup(&env)).unwrap();
        assert_eq!(config.port, 3101);
        assert_eq!(config.db_pool_size, 24);
    }

    #[test]
    fn live_needs_oanda_and_keeps_a_small_pool() {
        let err = Config::from_lookup(Mode::Live, lookup(&[("DATABASE_URL", "postgres://x")]))
            .unwrap_err();
        assert!(err.to_string().contains("OANDA_API_KEY"));

        let mut env = LIVE_ENV.to_vec();
        env.push(("AURO_TESTER_DB_POOL_SIZE", "24"));
        let config = Config::from_lookup(Mode::Live, lookup(&env)).unwrap();
        assert_eq!(config.port, 3000);
        assert_eq!(config.db_pool_size, 5);
    }

    #[test]
    fn a_pool_size_that_isnt_a_positive_number_is_refused() {
        let mut env = LIVE_ENV.to_vec();
        env.push(("AURO_LIVE_DB_POOL_SIZE", "0"));
        assert!(Config::from_lookup(Mode::Live, lookup(&env)).is_err());
    }
}
