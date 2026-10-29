defmodule OpusWeb.OptionsLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Opus.Options

  test "renders the form with a cash-secured put as the default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?view=workbench")
    assert html =~ "Your own contract"
    refute html =~ "Show me what happens"

    {:ok, _view, html} = live(conn, ~p"/options?view=custom")

    assert html =~ "Options"
    # The WallStreetBets wording is rendered beside the serious wording; the theme picks one.
    assert html =~ "Casino"
    assert html =~ "Sell a put (cash-secured)"
    assert html =~ "Show me what happens"
  end

  test "input mistakes are explained before anything is sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options?view=custom")

    html =
      view
      |> form("#position-form", position: %{"strike" => "", "premium" => "6.4"})
      |> render_submit()

    assert html =~ "Strike is required."
  end

  # config/test.exs points the Auro client at a closed port.
  test "a complete position reports that Auro is unreachable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options?view=custom")

    html =
      view
      |> form("#position-form",
        position: %{"strike" => "640", "premium" => "6.40", "expiration" => "2026-12-18"}
      )
      |> render_submit()

    assert html =~ "Auro is not running."
  end

  test "the covered-call cost basis field appears only for covered calls", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/options?view=custom")
    refute html =~ "Your shares cost"

    html =
      view
      |> form("#position-form", position: %{"strategy" => "covered_call"})
      |> render_change()

    assert html =~ "Your shares cost"
  end

  describe "Options.build_request/1" do
    test "maps the strategy to kind and side and converts volatility from percent" do
      assert {:ok, request} =
               Options.build_request(%{
                 "underlying" => " spy ",
                 "strategy" => "covered_call",
                 "strike" => "670",
                 "premium" => "$4.00",
                 "expiration" => "2026-12-18",
                 "contracts" => "2",
                 "spot" => "",
                 "sigma" => "18",
                 "cost_basis" => "600"
               })

      assert request == %{
               underlying: "SPY",
               kind: "call",
               side: "sell",
               strike: 670.0,
               premium: 4.0,
               expiration: "2026-12-18",
               contracts: 2.0,
               sigma: 0.18,
               cost_basis: 600.0
             }
    end

    test "rejects non-positive numbers and bad dates" do
      base = %{
        "underlying" => "SPY",
        "strategy" => "long_call",
        "strike" => "660",
        "premium" => "5",
        "expiration" => "2026-12-18"
      }

      assert {:error, "Premium must be a positive number."} =
               Options.build_request(%{base | "premium" => "-1"})

      assert {:error, "Expiration must be a date."} =
               Options.build_request(%{base | "expiration" => "soon"})

      assert {:error, "Pick a strategy."} = Options.build_request(%{base | "strategy" => "x"})
    end
  end
end
