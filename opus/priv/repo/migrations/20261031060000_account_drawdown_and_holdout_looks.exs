defmodule Opus.Repo.Migrations.AccountDrawdownAndHoldoutLooks do
  use Ecto.Migration

  @moduledoc """
  RULES_VERSION 5 (Fable review, Oct 31 2026).

  - The backtest's drawdown gate reads the account's worst drop
    (`account_max_drawdown`, at the strategy's risk a trade but never under
    1%) instead of the trades-added-up one (`max_drawdown`), so one market
    and a basket meet the same bar on the same basis. Same 25%.
  - The holdout's Sharpe bar reads `annual_sharpe_after_looks`: the annual
    Sharpe less a luck allowance for every other look of the same idea at
    the sealed window. With one look it is the annual Sharpe. Same 0.3.
  """

  @timeframes ~w(M1 M5 M15 H1 H4)

  def up do
    execute """
    DELETE FROM validation_thresholds
    WHERE stage = 'backtest' AND metric = 'max_drawdown'
      AND instrument_class = 'all' AND strategy_type = 'all'
    """

    for tf <- @timeframes do
      execute """
      INSERT INTO validation_thresholds
        (stage, timeframe_class, metric, operator, value, description,
         instrument_class, strategy_type, inserted_at, updated_at)
      VALUES ('backtest', '#{tf}', 'account_max_drawdown', 'lte', 0.25,
              'The account fell at most 25% from its high, at its risk a trade (at least 1%)',
              'all', 'all', now(), now())
      """
    end

    execute """
    UPDATE validation_thresholds
    SET metric = 'annual_sharpe_after_looks',
        description = 'Annual Sharpe on the holdout, less a luck allowance for other looks at it',
        updated_at = now()
    WHERE stage = 'holdout' AND metric = 'annual_sharpe'
    """
  end

  def down do
    execute """
    UPDATE validation_thresholds
    SET metric = 'annual_sharpe',
        description = 'Annual Sharpe at least 0.3 on the year kept aside: the edge did not vanish',
        updated_at = now()
    WHERE stage = 'holdout' AND metric = 'annual_sharpe_after_looks'
    """

    execute "DELETE FROM validation_thresholds WHERE metric = 'account_max_drawdown'"

    for tf <- @timeframes do
      execute """
      INSERT INTO validation_thresholds
        (stage, timeframe_class, metric, operator, value, description,
         instrument_class, strategy_type, inserted_at, updated_at)
      VALUES ('backtest', '#{tf}', 'max_drawdown', 'lte', 0.25,
              'Worst drop at most 25%', 'all', 'all', now(), now())
      """
    end
  end
end
