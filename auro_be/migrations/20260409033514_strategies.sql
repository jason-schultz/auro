CREATE TABLE strategies (
    id UUID PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    instrument VARCHAR(20) NOT NULL,
    granularity VARCHAR(5) NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT false,
    config JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_strategies_instrument ON strategies (instrument);
CREATE INDEX idx_strategies_enabled ON strategies (enabled);
