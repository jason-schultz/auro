defmodule Opus.Repo.Migrations.SeedHoldoutThresholds do
  use Ecto.Migration

  @moduledoc """
  Gates for the pipeline's sealed-holdout stage (Rust `run_holdout`): the one
  look at bars after trading_config.pipeline_holdout_start, taken only after a
  candidate has passed every exploration stage. Metrics are the backtest
  stats plus holdout_start and holdout_looks.

  The bars are deliberately modest. A holdout can't be re-tuned against, so
  the question is only "did it keep working", not "is it impressive":
  positive return, Sharpe >= 0.3 (the figure pre-registered for the manual
  lockbox look of 2026-10-17), and enough trades to mean anything.
  """

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    execute("""
    INSERT INTO validation_thresholds (stage, timeframe_class, instrument_class, strategy_type, metric, operator, value, description, inserted_at, updated_at) VALUES
      ('holdout', 'h4',       'all', 'all', 'num_trades',   'gte', 5,   'Minimum trades entered inside the holdout window', '#{now}', '#{now}'),
      ('holdout', 'h1',       'all', 'all', 'num_trades',   'gte', 8,   'Minimum trades entered inside the holdout window', '#{now}', '#{now}'),
      ('holdout', 'intraday', 'all', 'all', 'num_trades',   'gte', 15,  'Minimum trades entered inside the holdout window', '#{now}', '#{now}'),
      ('holdout', 'scalp',    'all', 'all', 'num_trades',   'gte', 30,  'Minimum trades entered inside the holdout window', '#{now}', '#{now}'),
      ('holdout', 'h4',       'all', 'all', 'sharpe',       'gte', 0.3, 'Holdout Sharpe (pre-registered lockbox bar)',      '#{now}', '#{now}'),
      ('holdout', 'h1',       'all', 'all', 'sharpe',       'gte', 0.3, 'Holdout Sharpe (pre-registered lockbox bar)',      '#{now}', '#{now}'),
      ('holdout', 'intraday', 'all', 'all', 'sharpe',       'gte', 0.3, 'Holdout Sharpe (pre-registered lockbox bar)',      '#{now}', '#{now}'),
      ('holdout', 'scalp',    'all', 'all', 'sharpe',       'gte', 0.3, 'Holdout Sharpe (pre-registered lockbox bar)',      '#{now}', '#{now}'),
      ('holdout', 'h4',       'all', 'all', 'total_return', 'gt',  0.0, 'Holdout return must be positive',                  '#{now}', '#{now}'),
      ('holdout', 'h1',       'all', 'all', 'total_return', 'gt',  0.0, 'Holdout return must be positive',                  '#{now}', '#{now}'),
      ('holdout', 'intraday', 'all', 'all', 'total_return', 'gt',  0.0, 'Holdout return must be positive',                  '#{now}', '#{now}'),
      ('holdout', 'scalp',    'all', 'all', 'total_return', 'gt',  0.0, 'Holdout return must be positive',                  '#{now}', '#{now}')
    """)
  end

  def down do
    execute("DELETE FROM validation_thresholds WHERE stage = 'holdout'")
  end
end
