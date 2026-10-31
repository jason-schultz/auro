defmodule Opus.Pipeline.CoordinatorTest do
  # Not async: it adds instruments, whose unique keys other files' tests
  # share; two adding the same ones in parallel can deadlock.
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.{Coordinator, StrategyConfig}

  defp config!(instrument) do
    %StrategyConfig{}
    |> StrategyConfig.changeset(%{
      instrument: instrument,
      granularity: "D",
      strategy_type: "composite",
      parameters: %{"instrument" => instrument}
    })
    |> Repo.insert!()
  end

  test "the pipeline list leaves the archive out unless asked" do
    {:ok, _} = Instruments.add("EUR_USD", "fx_major")
    {:ok, _} = Instruments.add("GBP_USD", "fx_major")
    kept = config!("EUR_USD")
    old = config!("GBP_USD")

    from(c in StrategyConfig, where: c.id == ^old.id)
    |> Repo.update_all(set: [archived_at: DateTime.utc_now()])

    assert [%{config_id: id, archived: false}] = Coordinator.list_pipeline_status()
    assert id == kept.id
    assert length(Coordinator.list_pipeline_status(true)) == 2
    assert Coordinator.count_archived() == 1
  end

  test "a config loads and saves without the archive column being read" do
    {:ok, _} = Instruments.add("EUR_USD", "fx_major")
    config = config!("EUR_USD")

    assert %StrategyConfig{archived_at: nil} = Repo.get!(StrategyConfig, config.id)
  end
end
