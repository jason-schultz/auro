CREATE TABLE account_snapshots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    nav DOUBLE PRECISION NOT NULL,
    balance DOUBLE PRECISION NOT NULL,
    unrealized_pl DOUBLE PRECISION NOT NULL,
    margin_used DOUBLE PRECISION NOT NULL,
    margin_available DOUBLE PRECISION NOT NULL,
    currency VARCHAR(10) NOT NULL,
    open_position_count INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_account_snapshots_timestamp ON account_snapshots (timestamp DESC);
