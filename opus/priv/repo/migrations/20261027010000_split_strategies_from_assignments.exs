defmodule Opus.Repo.Migrations.SplitStrategiesFromAssignments do
  use Ecto.Migration

  @moduledoc """
  Phase 1 of research/strategy_assignments_plan.md: a strategy (recipe) is
  stored once in `strategies`, and each `live_strategies` row becomes an
  assignment of a recipe to an instrument, with its own sizing and action.

  - The old `strategies` table (never used, 0 rows in prod) is renamed to
    `strategies_legacy`, not dropped.
  - `strategies.definition` is the strategy JSON without `instrument`,
    `granularity` and `sizing`. Identical recipes are stored once (unique
    on timeframe + definition).
  - Transition only: `live_strategies.parameters` stays the thing writers
    send. A trigger derives the recipe and sizing from it on every insert
    or update, so Rust and Opus write exactly as before while Rust reads
    the recipe + assignment. Phase 1 step 4 drops `parameters` and this
    trigger together.
  - Backfill: every existing row is touched once so the trigger links it.
  """

  def up do
    execute("ALTER TABLE strategies RENAME TO strategies_legacy")
    execute("ALTER INDEX strategies_pkey RENAME TO strategies_legacy_pkey")

    execute("""
    CREATE TABLE strategies (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      name TEXT NOT NULL,
      granularity VARCHAR(5) NOT NULL,
      definition JSONB NOT NULL,
      notes TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    # md5 of the canonical jsonb text: a definition can outgrow a btree entry.
    execute(
      "CREATE UNIQUE INDEX strategies_recipe_key ON strategies (granularity, md5(definition::text))"
    )

    alter table(:live_strategies) do
      add :strategy_id, references(:strategies, type: :uuid, on_delete: :restrict)
      add :sizing, :map
      add :action, :map, null: false, default: fragment(~s['{"type": "oanda"}'::jsonb])
    end

    create index(:live_strategies, [:strategy_id])

    execute("""
    CREATE FUNCTION live_strategies_link_recipe() RETURNS trigger AS $$
    DECLARE
      recipe JSONB := NEW.parameters - 'instrument' - 'granularity' - 'sizing';
    BEGIN
      INSERT INTO strategies (name, granularity, definition)
      VALUES (COALESCE(NEW.parameters->>'strategy_name', NEW.strategy_type), NEW.granularity, recipe)
      ON CONFLICT (granularity, md5(definition::text)) DO NOTHING;

      SELECT id INTO NEW.strategy_id
      FROM strategies
      WHERE granularity = NEW.granularity
        AND md5(definition::text) = md5(recipe::text);

      NEW.sizing := NEW.parameters->'sizing';
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER live_strategies_link_recipe
    BEFORE INSERT OR UPDATE OF parameters, granularity, strategy_type ON live_strategies
    FOR EACH ROW EXECUTE FUNCTION live_strategies_link_recipe()
    """)

    execute("UPDATE live_strategies SET parameters = parameters")
    execute("ALTER TABLE live_strategies ALTER COLUMN strategy_id SET NOT NULL")
  end

  def down do
    execute("DROP TRIGGER live_strategies_link_recipe ON live_strategies")
    execute("DROP FUNCTION live_strategies_link_recipe()")

    alter table(:live_strategies) do
      remove :action
      remove :sizing
      remove :strategy_id
    end

    execute("DROP TABLE strategies")
    execute("ALTER INDEX strategies_legacy_pkey RENAME TO strategies_pkey")
    execute("ALTER TABLE strategies_legacy RENAME TO strategies")
  end
end
