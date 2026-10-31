defmodule Opus.MarketData.ShareHistoryWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Instruments
  alias Opus.MarketData.ShareHistoryWorker

  test "adding a stock or ETF queues its history and dividends; an OANDA market doesn't" do
    {:ok, msft} = Instruments.add("MSFT", "equity")
    {:ok, gold} = Instruments.add("XAU_USD", "metal")

    assert_enqueued(worker: ShareHistoryWorker, args: %{instrument_id: msft.id})
    refute_enqueued(worker: ShareHistoryWorker, args: %{instrument_id: gold.id})
  end

  test "setting a market's broker to one that holds shares queues it too" do
    {:ok, shop} = Instruments.add("SHOP", "equity")
    {:ok, shop} = Instruments.set_broker(shop, nil)
    Repo.delete_all(Oban.Job)

    {:ok, _} = Instruments.set_broker(shop, "wealthsimple")
    assert_enqueued(worker: ShareHistoryWorker, args: %{instrument_id: shop.id})
  end

  test "a market with deep history and no dividend source has nothing to load" do
    {:ok, sde} = Instruments.add("SDE.TO", "equity")

    Repo.insert_all("candles", [
      %{
        instrument_id: sde.id,
        instrument: "SDE.TO",
        granularity: "D",
        timestamp: ~U[2010-01-04 05:00:00Z],
        open: 1.0,
        high: 1.0,
        low: 1.0,
        close: 1.0,
        complete: true
      }
    ])

    assert :ok = perform_job(ShareHistoryWorker, %{instrument_id: sde.id})
  end

  test "without the engine, the load fails and is tried again later" do
    {:ok, msft} = Instruments.add("MSFT", "equity")

    assert {:error, {:history, "MSFT", _reason}} =
             perform_job(ShareHistoryWorker, %{instrument_id: msft.id})
  end
end
