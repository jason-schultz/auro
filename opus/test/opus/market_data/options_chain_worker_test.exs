defmodule Opus.MarketData.OptionsChainWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Instruments
  alias Opus.MarketData.OptionsChainWorker

  setup do
    config = Application.fetch_env!(:opus, OptionsChainWorker)
    on_exit(fn -> Application.put_env(:opus, OptionsChainWorker, config) end)
    %{config: config}
  end

  defp flag_for_chains(spelling) do
    {:ok, instrument} = Instruments.add(spelling, "etf")
    {:ok, instrument} = Instruments.toggle(instrument, :feed_options_chain)
    instrument
  end

  test "the cron shape enqueues nothing while disabled", %{config: config} do
    flag_for_chains("SPY")
    Application.put_env(:opus, OptionsChainWorker, Keyword.put(config, :enabled, false))

    assert :ok = perform_job(OptionsChainWorker, %{})
    assert all_enqueued(worker: OptionsChainWorker) == []
  end

  test "the cron shape fans out one job per flagged listing when enabled", %{config: config} do
    flag_for_chains("SPY")
    flag_for_chains("XIU.TO")
    {:ok, _unflagged} = Instruments.add("QQQ", "etf")
    Application.put_env(:opus, OptionsChainWorker, Keyword.put(config, :enabled, true))

    assert :ok = perform_job(OptionsChainWorker, %{})

    jobs = all_enqueued(worker: OptionsChainWorker)
    assert Enum.sort(Enum.map(jobs, & &1.args["underlying"])) == ["SPY", "XIU.TO"]
  end

  test "an underlying job reports the engine failure instead of swallowing it" do
    # config/test.exs points the Auro client at a closed port.
    assert {:error, _reason} = perform_job(OptionsChainWorker, %{"underlying" => "SPY"})
  end
end
