defmodule Opus.Repo.Migrations.AddStrategyTypeToValidationThresholds do
  use Ecto.Migration

  def up do
    # Add strategy_type with default 'all' — existing rows become strategy_type='all'
    alter table(:validation_thresholds) do
      add :strategy_type, :string, null: false, default: "all"
    end

    # Drop old PK (stage, timeframe_class, instrument_class, metric)
    drop constraint(:validation_thresholds, "validation_thresholds_pkey")

    # Recreate PK with strategy_type included
    execute """
    ALTER TABLE validation_thresholds
    ADD PRIMARY KEY (stage, timeframe_class, instrument_class, strategy_type, metric)
    """
  end

  def down do
    drop constraint(:validation_thresholds, "validation_thresholds_pkey")

    execute """
    ALTER TABLE validation_thresholds
    ADD PRIMARY KEY (stage, timeframe_class, instrument_class, metric)
    """

    alter table(:validation_thresholds) do
      remove :strategy_type
    end
  end
end
