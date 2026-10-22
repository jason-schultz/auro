ALTER TABLE live_strategies
ADD COLUMN IF NOT EXISTS curator_mode VARCHAR(16) NOT NULL DEFAULT 'auto';

UPDATE live_strategies
SET curator_mode = CASE WHEN enabled THEN 'pinned_on' ELSE 'auto' END
WHERE curator_mode IS NULL OR curator_mode = 'auto';
