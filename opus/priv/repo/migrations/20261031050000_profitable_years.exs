defmodule Opus.Repo.Migrations.ProfitableYears do
  use Ecto.Migration

  @moduledoc """
  The backtest needs the account to have made money in at least 60% of the
  calendar years it traded (`profitable_years`, from the account valued
  every day; a year with no trade open doesn't count). Without it, one big
  year can carry a strategy that went nowhere the rest of the time.
  Every timeframe, every class. RULES_VERSION 4.
  """

  @timeframes ~w(M1 M5 M15 H1 H4)

  def up do
    for tf <- @timeframes do
      execute """
      INSERT INTO validation_thresholds
        (stage, timeframe_class, metric, operator, value, description,
         instrument_class, strategy_type, inserted_at, updated_at)
      VALUES ('backtest', '#{tf}', 'profitable_years', 'gte', 0.6,
              'Made money in at least 60% of the years it traded, not one big year',
              'all', 'all', now(), now())
      """
    end
  end

  def down do
    execute "DELETE FROM validation_thresholds WHERE metric = 'profitable_years'"
  end
end
