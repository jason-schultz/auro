defmodule Opus.MarketData.MassiveBarsWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.MarketData.MassiveBarsWorker

  test "the cron shape fans out one job per configured symbol and granularity" do
    config = Application.fetch_env!(:opus, MassiveBarsWorker)
    expected = length(config[:watchlist]) * length(config[:granularities])

    assert :ok = perform_job(MassiveBarsWorker, %{})

    jobs = all_enqueued(worker: MassiveBarsWorker)
    assert length(jobs) == expected
    assert Enum.all?(jobs, &(&1.args["days"] == config[:days]))
    assert Enum.any?(jobs, &(&1.args["symbol"] == "SPY" and &1.args["granularity"] == "D"))
  end

  test "enqueue_all with a backfill window carries that window on every job" do
    assert {:ok, count} = MassiveBarsWorker.enqueue_all(740)
    assert count > 0
    assert Enum.all?(all_enqueued(worker: MassiveBarsWorker), &(&1.args["days"] == 740))
  end

  test "a symbol job reports the engine failure instead of swallowing it" do
    # config/test.exs points the Auro client at a closed port.
    assert {:error, _reason} =
             perform_job(MassiveBarsWorker, %{
               "symbol" => "SPY",
               "granularity" => "D",
               "days" => 7
             })
  end
end
