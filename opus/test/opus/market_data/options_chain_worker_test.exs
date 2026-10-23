defmodule Opus.MarketData.OptionsChainWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.MarketData.OptionsChainWorker

  setup do
    config = Application.fetch_env!(:opus, OptionsChainWorker)
    on_exit(fn -> Application.put_env(:opus, OptionsChainWorker, config) end)
    %{config: config}
  end

  test "the cron shape enqueues nothing while disabled", %{config: config} do
    Application.put_env(:opus, OptionsChainWorker, Keyword.put(config, :enabled, false))

    assert :ok = perform_job(OptionsChainWorker, %{})
    assert all_enqueued(worker: OptionsChainWorker) == []
  end

  test "the cron shape fans out one job per configured underlying when enabled",
       %{config: config} do
    Application.put_env(:opus, OptionsChainWorker, Keyword.put(config, :enabled, true))

    assert :ok = perform_job(OptionsChainWorker, %{})

    jobs = all_enqueued(worker: OptionsChainWorker)
    assert length(jobs) == length(config[:underlyings])
    assert Enum.any?(jobs, &(&1.args["underlying"] == "SPY"))
  end

  test "an underlying job reports the engine failure instead of swallowing it" do
    # config/test.exs points the Auro client at a closed port.
    assert {:error, _reason} = perform_job(OptionsChainWorker, %{"underlying" => "SPY"})
  end
end
