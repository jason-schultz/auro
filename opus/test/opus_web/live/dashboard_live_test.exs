defmodule OpusWeb.DashboardLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # config/test.exs points the Auro client at a closed port: the engine is
  # down, which is itself something that needs the user.
  test "the home page leads with what needs the user, then the tiles", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    # The page shows at once and fills in when the background gather lands.
    assert html =~ "Checking everything"
    html = render_async(view)

    assert html =~ "1 thing needs you"
    assert html =~ "Auro (the Rust engine) is not running"
    assert html =~ "What to do:"
    assert html =~ "Paper options"
    assert html =~ "Index exposure"
    assert html =~ "Engine not reachable"

    # Broker balances arrive the same way; with the engine down they can't.
    assert html =~ "balances unavailable right now"
  end

  test "the nav leads with the dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/strategies")
    assert html =~ ~s(href="/")
    assert html =~ "War room"
  end
end
