defmodule Opus.DashboardTest do
  use Opus.DataCase, async: false

  alias Opus.Dashboard

  # config/test.exs points the Auro client at a closed port, so the engine
  # reads as down here.
  test "gathers an unreachable engine and a failed job into act-now alerts" do
    now = DateTime.utc_now()

    Repo.insert_all("oban_jobs", [
      %{
        worker: "Opus.MarketData.OptionsChainWorker",
        queue: "market_data",
        state: "discarded",
        attempted_at: DateTime.to_naive(DateTime.add(now, -3600)),
        errors: [%{"at" => "x", "attempt" => 1, "error" => "** (RuntimeError) boom\nstack"}]
      },
      %{
        worker: "Opus.Options.ScanWorker",
        queue: "market_data",
        state: "discarded",
        attempted_at: DateTime.to_naive(DateTime.add(now, -3 * 86_400)),
        errors: [%{"at" => "x", "attempt" => 1, "error" => "too old to show"}]
      }
    ])

    data = Dashboard.gather(now)
    alerts = Dashboard.alerts(data.input)

    assert data.input.engine == {:down, "Auro is not running."}
    refute data.live.engine_up
    assert length(data.books) == 7

    titles = Enum.map(alerts, & &1.title)
    assert "Auro (the Rust engine) is not running" in titles
    assert "Option chain snapshot failed" in titles
    refute Enum.any?(titles, &(&1 =~ "ideas scan failed"))

    failed = Enum.find(alerts, &(&1.title == "Option chain snapshot failed"))
    assert failed.detail == "(RuntimeError) boom"
    assert failed.clear_worker == "Opus.MarketData.OptionsChainWorker"

    # Clearing removes the recent failure; the alert goes with it.
    assert Dashboard.clear_failed_jobs("Opus.MarketData.OptionsChainWorker", now) == 1

    titles =
      now
      |> Dashboard.gather()
      |> Map.fetch!(:input)
      |> Dashboard.alerts()
      |> Enum.map(& &1.title)

    refute "Option chain snapshot failed" in titles
  end

  test "offline brokers found later join the alerts" do
    data = Dashboard.gather()
    alerts = Dashboard.alerts(data.input, [%{broker: "Questrade", error: "token"}])
    assert Enum.any?(alerts, &(&1.title == "Questrade is offline"))
  end
end
