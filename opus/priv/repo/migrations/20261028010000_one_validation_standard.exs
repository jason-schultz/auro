defmodule Opus.Repo.Migrations.OneValidationStandard do
  use Ecto.Migration

  @moduledoc """
  One pass/fail standard for every strategy, built on whether a result
  could be luck, in place of per-type floors calibrated in May to what the
  strategies of the day achieved. Rows are `strategy_type = 'all'` and
  `instrument_class = 'all'` for every timeframe class the engine looks up
  (`Granularity::timeframe_class`: M1, M5, M15, H1, H4; daily uses H4).

  - Backtest: at least 30 trades; t-statistic of the average trade at least
    2 (`t_stat` = per-trade Sharpe × √trades: a result this good would come
    from luck alone about 1 time in 40); drawdown at most 25%; made money.
  - Walk-forward: on the later data it wasn't fitted to, at least 20 trades,
    made money, and t-statistic at least 1 (the out-of-sample stretch is
    short, so the bar is lower; it has to point the same way).
  - Monte Carlo (bootstrap: trades drawn at random with replacement): at
    least 95% of the redrawn histories made money; a bad run (1 in 20)
    loses at most 35%.
  - Holdout: unchanged values. Its rows were stored under timeframe names
    the engine never looks up (h1, h4, intraday, scalp), so every holdout
    would have failed with "no thresholds configured"; they're renamed to
    H1, H4, M15 and M5 (intraday) and M1 (scalp).

  The table as it was is kept in `validation_thresholds_before_20261028`;
  `down` puts it back.
  """

  @classes ~w(M1 M5 M15 H1 H4)

  @standard [
    {"backtest", "num_trades", "gte", 30,
     "At least 30 trades, so the result isn't a handful of lucky ones"},
    {"backtest", "t_stat", "gte", 2.0,
     "Average trade at least 2 standard errors above zero: luck alone does this about 1 time in 40"},
    {"backtest", "max_drawdown", "lte", 0.25, "Worst drop at most 25%"},
    {"backtest", "total_return", "gt", 0, "Made money overall"},
    {"walk_forward", "oos_num_trades", "gte", 20,
     "At least 20 trades on the data it wasn't fitted to"},
    {"walk_forward", "oos_return", "gt", 0, "Made money on the data it wasn't fitted to"},
    {"walk_forward", "oos_t_stat", "gte", 1.0,
     "On the data it wasn't fitted to, the average trade is at least 1 standard error above zero"},
    {"monte_carlo", "profitable_pct", "gte", 0.95,
     "At least 95% of redrawn trade histories made money"},
    {"monte_carlo", "p95_drawdown", "lte", 0.35, "A bad run (1 in 20) loses at most 35%"}
  ]

  def up do
    execute("CREATE TABLE validation_thresholds_before_20261028 AS TABLE validation_thresholds")

    execute(
      "DELETE FROM validation_thresholds WHERE stage IN ('backtest', 'walk_forward', 'monte_carlo')"
    )

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for class <- @classes, {stage, metric, operator, value, description} <- @standard do
        %{
          stage: stage,
          timeframe_class: class,
          instrument_class: "all",
          strategy_type: "all",
          metric: metric,
          operator: operator,
          value: value / 1,
          description: description,
          inserted_at: now,
          updated_at: now
        }
      end

    flush()
    repo().insert_all("validation_thresholds", rows)

    execute("""
    INSERT INTO validation_thresholds
      (stage, timeframe_class, instrument_class, strategy_type, metric, operator, value,
       description, inserted_at, updated_at)
    SELECT stage, 'M5', instrument_class, strategy_type, metric, operator, value,
           description, now(), now()
    FROM validation_thresholds
    WHERE stage = 'holdout' AND timeframe_class = 'intraday'
    """)

    for {old, new} <- [{"h1", "H1"}, {"h4", "H4"}, {"intraday", "M15"}, {"scalp", "M1"}] do
      execute(
        "UPDATE validation_thresholds SET timeframe_class = '#{new}', updated_at = now() " <>
          "WHERE stage = 'holdout' AND timeframe_class = '#{old}'"
      )
    end
  end

  def down do
    execute("DELETE FROM validation_thresholds")

    execute(
      "INSERT INTO validation_thresholds SELECT * FROM validation_thresholds_before_20261028"
    )

    execute("DROP TABLE validation_thresholds_before_20261028")
  end
end
