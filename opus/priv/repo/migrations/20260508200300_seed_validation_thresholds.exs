defmodule Opus.Repo.Migrations.SeedValidationThresholds do
  use Ecto.Migration

  @doc """
  Initial threshold values for all pipeline gates. These can be tuned by
  updating rows directly — no migration needed for value changes.

  Metric names match the keys Rust writes to strategy_evaluations.stats:
    backtest:      sharpe, max_drawdown, num_trades, win_rate, total_return, expectancy
    walk_forward:  oos_sharpe, oos_return, oos_num_trades, sharpe_retention
    monte_carlo:   profitable_pct, median_sharpe, p95_drawdown

  To change a threshold:
    UPDATE validation_thresholds SET value = X, updated_at = NOW()
    WHERE stage = 'backtest' AND timeframe_class = 'h1' AND metric = 'sharpe';
  """

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    execute("""
    INSERT INTO validation_thresholds (stage, timeframe_class, metric, operator, value, description, inserted_at, updated_at) VALUES
      -- Backtest gates
      ('backtest', 'h4',       'num_trades',  'gte', 20,   'Minimum trades in backtest period',          '#{now}', '#{now}'),
      ('backtest', 'h1',       'num_trades',  'gte', 30,   'Minimum trades in backtest period',          '#{now}', '#{now}'),
      ('backtest', 'intraday', 'num_trades',  'gte', 60,   'Minimum trades in backtest period',          '#{now}', '#{now}'),
      ('backtest', 'scalp',    'num_trades',  'gte', 100,  'Minimum trades in backtest period',          '#{now}', '#{now}'),

      ('backtest', 'h4',       'sharpe',      'gte', 0.8,  'Minimum Sharpe ratio',                       '#{now}', '#{now}'),
      ('backtest', 'h1',       'sharpe',      'gte', 1.0,  'Minimum Sharpe ratio',                       '#{now}', '#{now}'),
      ('backtest', 'intraday', 'sharpe',      'gte', 1.2,  'Minimum Sharpe ratio',                       '#{now}', '#{now}'),
      ('backtest', 'scalp',    'sharpe',      'gte', 1.5,  'Minimum Sharpe ratio',                       '#{now}', '#{now}'),

      ('backtest', 'h4',       'max_drawdown', 'lte', 0.30, 'Maximum drawdown as positive fraction',     '#{now}', '#{now}'),
      ('backtest', 'h1',       'max_drawdown', 'lte', 0.25, 'Maximum drawdown as positive fraction',     '#{now}', '#{now}'),
      ('backtest', 'intraday', 'max_drawdown', 'lte', 0.20, 'Maximum drawdown as positive fraction',     '#{now}', '#{now}'),
      ('backtest', 'scalp',    'max_drawdown', 'lte', 0.15, 'Maximum drawdown as positive fraction',     '#{now}', '#{now}'),

      ('backtest', 'h4',       'expectancy',  'gt',  0.0,  'Expectancy = (win% * avg_win) - (loss% * avg_loss)', '#{now}', '#{now}'),
      ('backtest', 'h1',       'expectancy',  'gt',  0.0,  'Expectancy = (win% * avg_win) - (loss% * avg_loss)', '#{now}', '#{now}'),
      ('backtest', 'intraday', 'expectancy',  'gt',  0.0,  'Expectancy = (win% * avg_win) - (loss% * avg_loss)', '#{now}', '#{now}'),
      ('backtest', 'scalp',    'expectancy',  'gt',  0.0,  'Expectancy = (win% * avg_win) - (loss% * avg_loss)', '#{now}', '#{now}'),

      ('backtest', 'h4',       'total_return', 'gt',  0.0,  'Total return over backtest period must be positive', '#{now}', '#{now}'),
      ('backtest', 'h1',       'total_return', 'gt',  0.0,  'Total return over backtest period must be positive', '#{now}', '#{now}'),
      ('backtest', 'intraday', 'total_return', 'gt',  0.0,  'Total return over backtest period must be positive', '#{now}', '#{now}'),
      ('backtest', 'scalp',    'total_return', 'gt',  0.0,  'Total return over backtest period must be positive', '#{now}', '#{now}'),

      -- Walk-forward gates (70/30 IS/OOS ratio split)
      ('walk_forward', 'h4',       'oos_num_trades',   'gte', 6,    'Minimum trades in OOS window',        '#{now}', '#{now}'),
      ('walk_forward', 'h1',       'oos_num_trades',   'gte', 10,   'Minimum trades in OOS window',        '#{now}', '#{now}'),
      ('walk_forward', 'intraday', 'oos_num_trades',   'gte', 15,   'Minimum trades in OOS window',        '#{now}', '#{now}'),
      ('walk_forward', 'scalp',    'oos_num_trades',   'gte', 30,   'Minimum trades in OOS window',        '#{now}', '#{now}'),

      ('walk_forward', 'h4',       'oos_sharpe',       'gte', 0.5,  'Minimum OOS Sharpe ratio',            '#{now}', '#{now}'),
      ('walk_forward', 'h1',       'oos_sharpe',       'gte', 0.6,  'Minimum OOS Sharpe ratio',            '#{now}', '#{now}'),
      ('walk_forward', 'intraday', 'oos_sharpe',       'gte', 0.7,  'Minimum OOS Sharpe ratio',            '#{now}', '#{now}'),
      ('walk_forward', 'scalp',    'oos_sharpe',       'gte', 0.8,  'Minimum OOS Sharpe ratio',            '#{now}', '#{now}'),

      ('walk_forward', 'h4',       'oos_return',       'gt',  0.0,  'OOS period must be profitable',       '#{now}', '#{now}'),
      ('walk_forward', 'h1',       'oos_return',       'gt',  0.0,  'OOS period must be profitable',       '#{now}', '#{now}'),
      ('walk_forward', 'intraday', 'oos_return',       'gt',  0.0,  'OOS period must be profitable',       '#{now}', '#{now}'),
      ('walk_forward', 'scalp',    'oos_return',       'gt',  0.0,  'OOS period must be profitable',       '#{now}', '#{now}'),

      ('walk_forward', 'h4',       'sharpe_retention', 'gte', 0.50, 'OOS Sharpe / IS Sharpe must be >= X', '#{now}', '#{now}'),
      ('walk_forward', 'h1',       'sharpe_retention', 'gte', 0.50, 'OOS Sharpe / IS Sharpe must be >= X', '#{now}', '#{now}'),
      ('walk_forward', 'intraday', 'sharpe_retention', 'gte', 0.55, 'OOS Sharpe / IS Sharpe must be >= X', '#{now}', '#{now}'),
      ('walk_forward', 'scalp',    'sharpe_retention', 'gte', 0.60, 'OOS Sharpe / IS Sharpe must be >= X', '#{now}', '#{now}'),

      -- Monte Carlo gates (1000 simulations of shuffled trade sequences)
      ('monte_carlo', 'h4',       'profitable_pct', 'gte', 0.70, 'Fraction of simulations with positive return', '#{now}', '#{now}'),
      ('monte_carlo', 'h1',       'profitable_pct', 'gte', 0.70, 'Fraction of simulations with positive return', '#{now}', '#{now}'),
      ('monte_carlo', 'intraday', 'profitable_pct', 'gte', 0.75, 'Fraction of simulations with positive return', '#{now}', '#{now}'),
      ('monte_carlo', 'scalp',    'profitable_pct', 'gte', 0.80, 'Fraction of simulations with positive return', '#{now}', '#{now}'),

      ('monte_carlo', 'h4',       'median_sharpe',  'gte', 0.5,  'Median Sharpe across all simulations',         '#{now}', '#{now}'),
      ('monte_carlo', 'h1',       'median_sharpe',  'gte', 0.5,  'Median Sharpe across all simulations',         '#{now}', '#{now}'),
      ('monte_carlo', 'intraday', 'median_sharpe',  'gte', 0.6,  'Median Sharpe across all simulations',         '#{now}', '#{now}'),
      ('monte_carlo', 'scalp',    'median_sharpe',  'gte', 0.7,  'Median Sharpe across all simulations',         '#{now}', '#{now}'),

      ('monte_carlo', 'h4',       'p95_drawdown',   'lte', 0.35, '95th percentile max drawdown across sims',     '#{now}', '#{now}'),
      ('monte_carlo', 'h1',       'p95_drawdown',   'lte', 0.35, '95th percentile max drawdown across sims',     '#{now}', '#{now}'),
      ('monte_carlo', 'intraday', 'p95_drawdown',   'lte', 0.30, '95th percentile max drawdown across sims',     '#{now}', '#{now}'),
      ('monte_carlo', 'scalp',    'p95_drawdown',   'lte', 0.25, '95th percentile max drawdown across sims',     '#{now}', '#{now}')
    """)
  end

  def down do
    execute("DELETE FROM validation_thresholds")
  end
end
