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

  test "a fresh gather pushed by the feed replaces what the page shows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    data = Opus.Dashboard.gather()
    send(view.pid, {:dashboard, put_in(data.input.engine, :up)})
    html = render(view)

    refute html =~ "Auro (the Rust engine) is not running"
  end

  test "the nav leads with the dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/strategies")
    assert html =~ ~s(href="/")
    assert html =~ "War room"
  end

  describe "share alerts" do
    alias Opus.Repo
    alias Opus.Trading.{LiveStrategy, Recipe, ShareAlert}

    setup do
      Repo.delete_all(ShareAlert)
      Repo.delete_all(LiveStrategy)
      recipe = Repo.insert!(%Recipe{name: "Dip-buy shares", granularity: "D", definition: %{}})

      ls =
        Repo.insert!(%LiveStrategy{
          strategy_type: "composite",
          instrument: "SPY",
          granularity: "D",
          parameters: %{},
          enabled: true,
          action: %{"type" => "share_alert", "amount" => 500},
          recipe: recipe,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      alert =
        Repo.insert!(%ShareAlert{
          live_strategy_id: ls.id,
          day: Opus.Clock.today(),
          side: "buy",
          symbol: "SPY",
          currency: "USD",
          price: 120.0,
          stop_price: 110.0,
          shares: 4.0
        })

      %{alert: alert}
    end

    test "a waiting alert leads Needs you with Log trade", %{conn: conn, alert: alert} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      assert html =~ "2 things need you"
      assert html =~ "BUY 4 SPY at about $120.00 US, limit $120.24 US (Dip-buy shares)"
      assert html =~ "set a stop at $110.00 US"

      # The form opens filled in from the alert; with the engine down the
      # accounts can't be read, and it says so.
      html = view |> element("button[phx-value-id='#{alert.id}']", "Log trade") |> render_click()
      assert html =~ "Account it was filled in"
      assert html =~ ~s(value="120")
      assert html =~ ~s(value="-480")
      assert html =~ "The accounts can&#39;t be read right now"

      # Changing the shares moves the cash change with them.
      html =
        view
        |> form("#log-trade-form", fill: %{shares: "2"})
        |> render_change(%{"_target" => ["fill", "shares"]})

      assert html =~ ~s(value="-240.0")
    end

    test "Didn't trade takes it off the page", %{conn: conn, alert: alert} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      html =
        view |> element("button[phx-value-id='#{alert.id}']", "Didn't trade") |> render_click()

      refute html =~ "BUY 4 SPY"
      assert Repo.get!(ShareAlert, alert.id).status == "skipped"
    end
  end
end
