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

  test "lists your strategies with the trading ones picked", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/together")

    assert html =~ "Strategies together"
    assert html =~ "Run 1 together"
    assert has_element?(view, "input[type=checkbox][checked]", "")

    html = view |> form("form[phx-submit=run]", %{"plays" => []}) |> render_change()
    assert html =~ "Run 0 together"
  end

  test "says so when the engine can't run them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/together")

    view |> form("form[phx-submit=run]") |> render_submit()
    html = render_async(view, 10_000)

    refute html =~ "Running…"
    assert html =~ "engine"
  end
end
