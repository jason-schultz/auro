defmodule OpusWeb.AccountsLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # config/test.exs points the Auro client at a closed port, so the page
  # exercises its unreachable-engine state end to end.
  test "renders the frame, then reports that Auro is unreachable once connected", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/accounts")

    assert html =~ "Accounts"
    assert html =~ "Auro"
    assert render(view) =~ "Auro is not running."
  end

  test "refresh re-queries the engine and surfaces the same failure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/accounts")

    assert view |> element("button", "Refresh") |> render_click() =~ "Auro is not running."
  end
end
