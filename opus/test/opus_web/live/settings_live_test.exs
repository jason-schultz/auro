defmodule OpusWeb.SettingsLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Opus.Settings

  test "saving keeps an empty secret box from wiping the saved one", %{conn: conn} do
    :ok = Settings.put("OANDA_API_KEY", "first-key-0001")
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "ends …0001"
    refute html =~ "first-key"

    html =
      view
      |> form("#settings-oanda-form", %{
        "fields" => %{"OANDA_API_KEY" => "", "OANDA_ACCOUNT_ID" => "101-9"}
      })
      |> render_submit()

    assert Settings.get("OANDA_API_KEY") == "first-key-0001"
    assert Settings.get("OANDA_ACCOUNT_ID") == "101-9"
    assert html =~ "restart it to use them"
  end

  test "Remove takes a saved value away", %{conn: conn} do
    :ok = Settings.put("MASSIVE_BASE_URL", "https://example.test")
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element(~s(#settings-massive button[phx-value-name="MASSIVE_BASE_URL"]))
    |> render_click()

    assert Settings.get("MASSIVE_BASE_URL") == nil
  end
end
