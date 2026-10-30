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

    # Clearing marks the recent failure cleared; the alert goes with it, the
    # job and its error stay in the history, and a second clear finds nothing.
    assert Dashboard.clear_failed_jobs("Opus.MarketData.OptionsChainWorker", now) == 1
    assert Dashboard.clear_failed_jobs("Opus.MarketData.OptionsChainWorker", now) == 0

    assert [%{"cleared_at" => _}] =
             Repo.all(
               from(j in "oban_jobs",
                 where: j.worker == "Opus.MarketData.OptionsChainWorker",
                 select: j.meta
               )
             )

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

  @tag :capture_log
  test "a part that raises is named in an alert and the rest still go out" do
    # The paper books can't be valued without their starting cash.
    config = Application.fetch_env!(:opus, Opus.Options.Paper)
    on_exit(fn -> Application.put_env(:opus, Opus.Options.Paper, config) end)
    Application.put_env(:opus, Opus.Options.Paper, Keyword.delete(config, :starting_cash))

    data = Dashboard.gather()
    titles = data.input |> Dashboard.alerts() |> Enum.map(& &1.title)

    assert "Part of the dashboard failed to load: paper options books" in titles
    assert "Auro (the Rust engine) is not running" in titles
    assert data.books == []
    assert data.input.paper == []
  end

  @tag :capture_log
  test "a section stands in its default for a raise or an exit" do
    assert {%{a: 1}, []} = Dashboard.section({%{}, []}, :a, 0, fn -> 1 end)
    assert {%{a: 0}, [:a]} = Dashboard.section({%{}, []}, :a, 0, fn -> raise "boom" end)
    assert {%{a: 0}, [:a]} = Dashboard.section({%{}, []}, :a, 0, fn -> exit(:timeout) end)
  end
end
