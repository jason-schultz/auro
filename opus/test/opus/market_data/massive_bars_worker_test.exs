defmodule Opus.MarketData.MassiveBarsWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Instruments
  alias Opus.MarketData.MassiveBarsWorker

  defp flag_for_massive(spelling) do
    {:ok, instrument} = Instruments.add(spelling, "etf")
    {:ok, instrument} = Instruments.toggle(instrument, :feed_massive_daily)
    instrument
  end

  test "the cron shape fans out one job per flagged listing and granularity" do
    flag_for_massive("SPY")
    flag_for_massive("QQQ")
    # Flagged for another feed only: not this worker's.
    {:ok, aapl} = Instruments.add("AAPL", "equity")
    {:ok, _} = Instruments.toggle(aapl, :feed_questrade_bars)

    config = Application.fetch_env!(:opus, MassiveBarsWorker)
    expected = 2 * length(config[:granularities])

    assert :ok = perform_job(MassiveBarsWorker, %{})

    jobs = all_enqueued(worker: MassiveBarsWorker)
    assert length(jobs) == expected
    assert Enum.all?(jobs, &(&1.args["days"] == config[:days]))
    assert Enum.any?(jobs, &(&1.args["symbol"] == "SPY" and &1.args["granularity"] == "D"))
    refute Enum.any?(jobs, &(&1.args["symbol"] == "AAPL"))
  end

  test "enqueue_all with a backfill window carries that window on every job" do
    flag_for_massive("SPY")

    assert {:ok, count} = MassiveBarsWorker.enqueue_all(740)
    assert count > 0
    assert Enum.all?(all_enqueued(worker: MassiveBarsWorker), &(&1.args["days"] == 740))
  end

  test "nothing is flagged, nothing is enqueued" do
    assert {:ok, 0} = MassiveBarsWorker.enqueue_all(7)
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
