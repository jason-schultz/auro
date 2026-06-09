-- Single-row table for rotating Questrade OAuth2 tokens.
-- The singleton constraint enforces only one row ever exists.
CREATE TABLE questrade_tokens (
    singleton     BOOLEAN PRIMARY KEY DEFAULT TRUE,
    refresh_token TEXT        NOT NULL,
    access_token  TEXT,
    api_server    TEXT,
    expires_at    TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT singleton_check CHECK (singleton = TRUE)
);
