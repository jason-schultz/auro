defmodule Opus.Pipeline.EventsTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.{Events, StrategyConfig}

  @definition %{
    "version" => "1",
    "strategy_name" => "Momentum",
    "components" => %{"mo" => %{"type" => "Momentum", "params" => %{"lookback" => 5}}},
    "entry" => %{"long" => "mo.up"},
    "exit" => %{"long" => "mo.down"}
  }

  defp config(parameters) do
    {:ok, _} = Instruments.add("SPY", "etf")

    %StrategyConfig{}
    |> StrategyConfig.changeset(%{
      instrument: "SPY",
      granularity: "D",
      strategy_type: "composite",
      parameters: parameters
    })
    |> Repo.insert!()
  end

  test "a stage is announced to its own strategy's pages and to every-test pages" do
    # The test carries other names and its instrument, as stored configs do:
    # the strategy is its timeframe and trade settings only.
    %{id: id} =
      config(Map.merge(@definition, %{"strategy_name" => "Mo v2", "instrument" => "SPY"}))

    Events.subscribe(@definition, "D")
    Events.subscribe_all()

    Events.handle_event(
      [:oban, :job, :stop],
      %{},
      %{job: %{queue: "pipeline", args: %{"config_id" => id}}},
      nil
    )

    assert_receive {:pipeline_stage, ^id}
    assert_receive {:pipeline_stage, ^id}
  end

  test "another strategy's stages, or another queue's jobs, aren't announced to this one" do
    other = put_in(@definition, ["components", "mo", "params", "lookback"], 10)
    %{id: id} = config(other)

    Events.subscribe(@definition, "D")
    Events.broadcast(id)
    refute_receive {:pipeline_stage, _}

    Events.subscribe_all()

    Events.handle_event(
      [:oban, :job, :stop],
      %{},
      %{job: %{queue: "alerts", args: %{"config_id" => id}}},
      nil
    )

    refute_receive {:pipeline_stage, _}
  end
end
