CREATE TABLE IF NOT EXISTS wealthsimple_positions (
    id            SERIAL PRIMARY KEY,
    account_id    INTEGER          NOT NULL REFERENCES wealthsimple_accounts(id) ON DELETE CASCADE,
    symbol        TEXT             NOT NULL,
    shares        DOUBLE PRECISION NOT NULL,
    avg_cost      DOUBLE PRECISION,
    current_price DOUBLE PRECISION,
    updated_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);
