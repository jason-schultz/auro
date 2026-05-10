defmodule Opus.Repo.Migrations.CreateValidationThresholds do
  use Ecto.Migration

  @doc """
  Stores the pass/fail gate thresholds for each pipeline stage × timeframe class.
  Keyed by (stage, timeframe_class, metric) so individual thresholds can be
  updated via SQL without a code deploy.

  stage:           'backtest' | 'walk_forward' | 'monte_carlo'
  timeframe_class: 'h4' | 'h1' | 'intraday' | 'scalp'
  operator:        'gte' | 'lte' | 'gt' | 'lt'

  MTF strategies are classified by entry_granularity:
    H4-setup + H1-entry  -> 'h1' class
    H1-setup + M15-entry -> 'intraday' class

  Populated by the seed migration immediately following this one.
  Values can be updated directly in the DB to tune gates without deployment.
  """
  def change do
    create table(:validation_thresholds, primary_key: false) do
      add :stage, :string, primary_key: true
      add :timeframe_class, :string, primary_key: true
      add :metric, :string, primary_key: true
      add :operator, :string, null: false
      add :value, :float, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
