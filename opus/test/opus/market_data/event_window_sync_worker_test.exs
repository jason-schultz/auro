defmodule Opus.MarketData.EventWindowSyncWorkerTest do
  use ExUnit.Case, async: true

  alias Opus.MarketData.EventWindowSyncWorker, as: Sync

  @now ~U[2026-10-20 12:00:00Z]
  @calendars %{
    "fomc" => [~U[2026-09-16 18:00:00Z], ~U[2026-10-28 18:00:00Z], ~U[2026-12-09 19:00:00Z]]
  }

  defp params(component_params) do
    %{
      "components" => %{
        "ev" => %{"type" => "EventWindow", "params" => component_params},
        "rsi" => %{"type" => "RsiReversion", "params" => %{"rsi_period" => 2}}
      }
    }
  end

  test "fills a calendar-tagged EventWindow with recent and future events only" do
    assert {:changed, new} =
             Sync.refresh_parameters(
               params(%{"calendar" => "fomc", "events" => []}),
               @calendars,
               @now
             )

    assert new["components"]["ev"]["params"]["events"] ==
             ["2026-10-28T18:00:00Z", "2026-12-09T19:00:00Z"]

    assert new["components"]["rsi"] == params(%{})["components"]["rsi"]
  end

  test "unchanged when events already match" do
    current =
      params(%{
        "calendar" => "fomc",
        "events" => ["2026-10-28T18:00:00Z", "2026-12-09T19:00:00Z"]
      })

    assert :unchanged = Sync.refresh_parameters(current, @calendars, @now)
  end

  test "components without a known calendar are left alone" do
    assert :unchanged = Sync.refresh_parameters(params(%{"events" => []}), @calendars, @now)

    assert :unchanged =
             Sync.refresh_parameters(
               params(%{"calendar" => "gdp", "events" => []}),
               @calendars,
               @now
             )

    assert :unchanged = Sync.refresh_parameters(%{"version" => "1"}, @calendars, @now)
  end
end
