defmodule OpusWeb.DashboardLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # config/test.exs points the Auro client at a closed port: the engine is
  # down, which is itself something that needs the user.
  test "the home page leads with what needs the user, then the tiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render(view)

    assert html =~ "1 thing needs you"
    assert html =~ "Auro (the Rust engine) is not running"
    assert html =~ "What to do:"
    assert html =~ "Paper options"
    assert html =~ "Index exposure"
    assert html =~ "Engine not reachable"

    # Broker balances arrive after connect; with the engine down they can't.
    render_async(view)
    assert render(view) =~ "balances unavailable right now"
  end

  test "the nav leads with the dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/strategies")
    assert html =~ ~s(href="/")
    assert html =~ "War room"
  end
end
