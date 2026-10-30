defmodule Opus.Repo.Migrations.DeflatedSharpeAndParameterStability do
  use Ecto.Migration

  @moduledoc """
  Two more pass/fail rules, for every timeframe class the engine looks up
  (`Granularity::timeframe_class`: M1, M5, M15, H1, H4; daily uses H4), at
  `strategy_type = 'all'` and `instrument_class = 'all'` like the rest.

  - Walk-forward, `deflated_sharpe` ≥ 0.95: the backtest's per-trade Sharpe
    tested against the best Sharpe luck alone would give across every try
    of the same idea (Bailey & López de Prado 2014). The engine records it
    with its inputs (family, tries, their spread, the luck bar `sr0`).
  - Parameter stability, a new stage between Monte Carlo and the holdout:
    each numeric setting moved one step either way must still make money
    (`worst_total_return` > 0) and keep at least half the Sharpe
    (`worst_sharpe_retention` ≥ 0.5).

  `strategy_evaluations.stage` is a plain string with no check constraint,
  so the new stage needs no schema change. Until this runs, walk-forward
  records the deflated Sharpe without judging it, and parameter stability
  fails every config with "no thresholds configured".
  """

  @classes ~w(M1 M5 M15 H1 H4)

  @rules [
    {"walk_forward", "deflated_sharpe", "gte", 0.95,
     "At least a 95% chance the Sharpe isn't luck from trying many versions of the same idea"},
    {"parameter_stability", "worst_total_return", "gt", 0.0,
     "Still made money with each setting nudged one step either way"},
    {"parameter_stability", "worst_sharpe_retention", "gte", 0.5,
     "Kept at least half its Sharpe with each setting nudged one step either way: the edge doesn't hinge on one exact number"}
  ]

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for class <- @classes, {stage, metric, operator, value, description} <- @rules do
        %{
          stage: stage,
          timeframe_class: class,
          instrument_class: "all",
          strategy_type: "all",
          metric: metric,
          operator: operator,
          value: value,
          description: description,
          inserted_at: now,
          updated_at: now
        }
      end

    repo().insert_all("validation_thresholds", rows)
  end

  def down do
    for {stage, metric, _operator, _value, _description} <- @rules do
      execute(
        "DELETE FROM validation_thresholds WHERE stage = '#{stage}' AND metric = '#{metric}' " <>
          "AND instrument_class = 'all' AND strategy_type = 'all'"
      )
    end
  end
end
