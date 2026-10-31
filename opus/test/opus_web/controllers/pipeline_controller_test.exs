defmodule OpusWeb.PipelineControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.StrategyConfig
  alias Opus.Repo

  test "a config on a market that can't be tested yet is refused up front, with why", %{
    conn: conn
  } do
    {:ok, zzz} = Instruments.add("ZZZ", "index")
    {:ok, _} = Instruments.set_broker(zzz, nil)

    conn =
      post(conn, ~p"/api/strategy-configs", %{
        "instrument" => "ZZZ",
        "granularity" => "D",
        "parameters" => %{}
      })

    assert %{"error" => "not testable", "details" => details} = json_response(conn, 422)
    assert details =~ "ZZZ has no broker set for its tests"
    assert Repo.all(StrategyConfig) == []
  end

  test "a testable config is stored", %{conn: conn} do
    {:ok, _} = Instruments.add("XAU_USD", "metal")

    conn =
      post(conn, ~p"/api/strategy-configs", %{
        "instrument" => "XAU_USD",
        "granularity" => "D",
        "parameters" => %{}
      })

    assert %{"config_id" => _} = json_response(conn, 200)
  end
end
