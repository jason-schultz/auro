defmodule Opus.Pipeline.PromoteWorkerTest do
  # Not async: it adds instruments, whose unique keys other files' tests
  # share; two adding the same ones in parallel can deadlock.
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.{PromoteWorker, StrategyConfig}

  # The Rust engine is a closed port in tests, so a promote fails here.

  @tag :capture_log
  test "a failed promote is an error, so Oban retries it" do
    {:ok, _eur} = Instruments.add("EUR_USD", "fx_major")

    config =
      %StrategyConfig{}
      |> StrategyConfig.changeset(%{
        instrument: "EUR_USD",
        granularity: "H1",
        strategy_type: "composite",
        parameters: %{"instrument" => "EUR_USD"}
      })
      |> Repo.insert!()

    assert {:error, _reason} =
             PromoteWorker.perform(%Oban.Job{args: %{"config_id" => config.id}})
  end

  test "a config that doesn't exist is cancelled, not retried" do
    assert {:cancel, :not_found} =
             PromoteWorker.perform(%Oban.Job{args: %{"config_id" => Ecto.UUID.generate()}})
  end
end
