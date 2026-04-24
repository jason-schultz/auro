use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub oanda_api_key: String,
    pub oanda_account_id: String,
    pub oanda_base_url: String,
    pub oanda_stream_url: String,
    pub host: String,
    pub port: u16,
}

impl Config {
    pub fn from_env() -> Result<Self, env::VarError> {
        Ok(Self {
            database_url: env::var("DATABASE_URL")?,
            oanda_api_key: env::var("OANDA_API_KEY")?,
            oanda_account_id: env::var("OANDA_ACCOUNT_ID")?,
            oanda_base_url: env::var("OANDA_BASE_URL")?,
            oanda_stream_url: env::var("OANDA_STREAM_URL")?,
            host: env::var("HOST").unwrap_or_else(|_| "127.0.0.1".to_string()),
            port: env::var("PORT")
                .unwrap_or_else(|_| "3000".to_string())
                .parse()
                .expect("PORT must be a valid u16"),
        })
    }

    pub fn listen_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}
