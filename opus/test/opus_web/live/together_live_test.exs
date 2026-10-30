defmodule OpusWeb.TogetherLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Rule, Suspension}

  setup do
    for schema <- [Suspension, Rule, LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    now = DateTime.utc_now()

    recipe =
      Repo.insert!(%Recipe{
        name: "Index dip-buy",
        granularity: "D",
        definition: %{"strategy_name" => "Index dip-buy", "components" => %{}}
      })

    for {instrument, enabled} <- [{"SPX500_USD", true}, {"EU50_EUR", false}] do
      Repo.insert!(%LiveStrategy{
        strategy_type: "composite",
        instrument: instrument,
        granularity: "D",
        parameters: %{"strategy_name" => "Index dip-buy"},
        strategy_id: recipe.id,
        enabled: enabled,
        created_at: now,
        updated_at: now
      })
    end

    :ok
  end

  test "starts the team with the strategies trading now", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/together")

    assert html =~ "Strategies together"
    assert html =~ "1 strategy, all trading now"
    assert html =~ "Run the team to see what it does."

    html = view |> element("button[aria-label*=SPX500_USD]") |> render_click()
    assert html =~ "nobody yet"
  end

  test "the picker adds a strategy that isn't on the team", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/together")

    html = view |> element("button", "Add a strategy") |> render_click()
    assert html =~ "EU50_EUR"

    html = view |> element("li button", "Add") |> render_click()
    assert html =~ "2 strategies, 1 trading now"
  end

  test "says so when the engine can't run them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/together")

    view |> element("button", "See how they do together") |> render_click()
    html = render_async(view, 10_000)

    refute html =~ "Running…"
    # Together runs in the tester (config/test.exs: a closed port).
    assert html =~ "cargo run --release --bin auro-tester"
  end
end
