defmodule Opus.Trading.DriftWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Trading.{DriftWorker, LiveStrategy, LiveTrade, Recipe}

  @moduletag :capture_log

  setup do
    for schema <- [LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    now = DateTime.utc_now()

    # Saving an assignment files its rules as a recipe (strategy_id).
    Repo.insert!(%LiveStrategy{
      strategy_type: "composite",
      instrument: "SPX500_USD",
      granularity: "D",
      parameters: %{
        "version" => "1",
        "strategy_name" => "Drift worker test",
        "components" => %{"mo" => %{"type" => "Momentum", "params" => %{"lookback" => 5}}},
        "entry" => %{"long" => "mo.up"},
        "exit" => %{"long" => "mo.down"},
        "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}},
        "instrument" => "SPX500_USD",
        "granularity" => "D"
      },
      enabled: true,
      created_at: now,
      updated_at: now
    })

    :ok
  end

  test "with the tester down the daily check waits and tries again" do
    # config/test.exs points the tester at a closed port.
    assert {:snooze, _seconds} = perform_job(DriftWorker, %{})
  end
end
