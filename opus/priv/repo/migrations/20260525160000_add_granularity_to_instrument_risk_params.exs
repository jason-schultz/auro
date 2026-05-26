defmodule Opus.Repo.Migrations.AddGranularityToInstrumentRiskParams do
  use Ecto.Migration

  def up do
    if instrument_risk_params_table_exists?() do
      # Drop existing rows. They all hold default values and are now covered by
      # the granularity-aware fallback in auro_be/risk_params.rs::fallback.
      execute "DELETE FROM instrument_risk_params"

      execute "ALTER TABLE instrument_risk_params DROP CONSTRAINT instrument_risk_params_pkey"

      alter table(:instrument_risk_params) do
        add :granularity, :string, size: 5, null: false
      end

      execute """
      ALTER TABLE instrument_risk_params
      ADD PRIMARY KEY (instrument, strategy_type, granularity)
      """
    end
  end

  def down do
    if instrument_risk_params_table_exists?() do
      execute "ALTER TABLE instrument_risk_params DROP CONSTRAINT instrument_risk_params_pkey"

      alter table(:instrument_risk_params) do
        remove :granularity
      end

      execute """
      ALTER TABLE instrument_risk_params
      ADD PRIMARY KEY (instrument, strategy_type)
      """
    end
  end

  defp instrument_risk_params_table_exists? do
    %{rows: [[exists?]]} =
      repo().query!("SELECT to_regclass('public.instrument_risk_params') IS NOT NULL")

    exists?
  end
end
