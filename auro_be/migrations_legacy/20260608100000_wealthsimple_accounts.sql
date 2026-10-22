CREATE TABLE IF NOT EXISTS wealthsimple_accounts (
    id           SERIAL PRIMARY KEY,
    account_type TEXT             NOT NULL,
    account_number TEXT,
    currency     TEXT             NOT NULL DEFAULT 'CAD',
    cash         DOUBLE PRECISION,
    market_value DOUBLE PRECISION,
    total_equity DOUBLE PRECISION,
    updated_at   TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);
