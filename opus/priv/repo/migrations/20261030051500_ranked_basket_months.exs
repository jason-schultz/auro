defmodule Opus.Repo.Migrations.RankedBasketMonths do
  use Ecto.Migration

  @moduledoc """
  A ranked basket is judged on the account's calendar-month returns, not
  its trades: it holds positions across rebalances, so a 9-year monthly
  carry book showed 26 "trades" and the 30-trade minimum and per-trade
  t-stat meant nothing. The engine (`pipeline::months_rules`) drops every
  trade-count rule for a ranked basket and looks for the months rule that
  replaces it under `strategy_type = 'ranked_basket'`; with none, the stage
  fails saying the months minimum isn't set up.

  The months minimums keep the trade minimums' proportions (36 months for
  30 trades): backtest 36, walk-forward halves 24 each (20 trades), holdout
  6 (5 trades; the holdout is about a year of data). Baskets run on daily
  or 4-hour bars only, both timeframe class H4.
  """

  @rows [
    {"backtest", "num_months", 36.0,
     "At least 36 months of results (3 years), judged on the account's monthly returns"},
    {"walk_forward", "is_num_months", 24.0,
     "At least 24 months of results on the data it was fitted to"},
    {"walk_forward", "oos_num_months", 24.0, "At least 24 months of results on unseen data"},
    {"holdout", "num_months", 6.0, "At least 6 months of results in the holdout"}
  ]

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {stage, metric, value, description} <- @rows do
        %{
          stage: stage,
          timeframe_class: "H4",
          instrument_class: "all",
          strategy_type: "ranked_basket",
          metric: metric,
          operator: "gte",
          value: value,
          description: description,
          inserted_at: now,
          updated_at: now
        }
      end

    repo().insert_all("validation_thresholds", rows)
  end

  def down do
    execute("DELETE FROM validation_thresholds WHERE strategy_type = 'ranked_basket'")
  end
end
