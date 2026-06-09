defmodule Opus.Repo.Migrations.LoosenMeanReversionBacktestThresholds do
  use Ecto.Migration

  @doc """
  Loosens mean_reversion backtest thresholds to match the trend_following tier.
  Updates existing mean_reversion rows in validation_thresholds with
  instrument_class='all'.
  """
  def up do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.05, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H1'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.30, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H1'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.15, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.35, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 12, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.07, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.20, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 50, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.06, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.18, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 80, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)
  end

  def down do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.25, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H1'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.25, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H1'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.30, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.25, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 15, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'H4'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.20, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.18, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 60, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M15'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.12, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'sharpe'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 0.12, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'max_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET value = 100, updated_at = NOW()
    WHERE stage = 'backtest'
      AND timeframe_class = 'M5'
      AND instrument_class = 'all'
      AND strategy_type = 'mean_reversion'
      AND metric = 'num_trades'
    """)
  end
end
