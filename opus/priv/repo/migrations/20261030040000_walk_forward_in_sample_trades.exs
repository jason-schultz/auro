defmodule Opus.Repo.Migrations.WalkForwardInSampleTrades do
  use Ecto.Migration

  @moduledoc """
  Walk-forward needs trades in the fitting half too: at least 20, the same
  as the unseen half. Without it a strategy whose trades all fall in the
  unseen half "passed" walk-forward with nothing to compare against (EUR_JPY
  carry, Oct 30: 0 fitting-half trades, 39 unseen). The engine already
  records `is_num_trades`.
  """

  @classes ~w(M1 M5 M15 H1 H4)

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for class <- @classes do
        %{
          stage: "walk_forward",
          timeframe_class: class,
          instrument_class: "all",
          strategy_type: "all",
          metric: "is_num_trades",
          operator: "gte",
          value: 20.0,
          description:
            "At least 20 trades on the data it was fitted to, so there's something to compare the unseen data against",
          inserted_at: now,
          updated_at: now
        }
      end

    repo().insert_all("validation_thresholds", rows)
  end

  def down do
    execute(
      "DELETE FROM validation_thresholds WHERE stage = 'walk_forward' AND metric = 'is_num_trades'"
    )
  end
end
