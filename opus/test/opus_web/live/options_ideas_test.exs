defmodule OpusWeb.OptionsIdeasTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Options
  alias Opus.Options.Idea
  alias Opus.Repo

  setup do
    Repo.delete_all(Idea)
    Repo.delete_all("option_quotes")
    Repo.delete_all("option_contracts")
    {:ok, iwm} = Instruments.add("IWM", "etf")
    now = ~N[2026-10-24 02:00:03]

    {_, [%{id: contract_id}]} =
      Repo.insert_all(
        "option_contracts",
        [
          %{
            ticker: "O:IWM261218C00235000",
            underlying: "IWM",
            contract_type: "call",
            expiration_date: ~D[2026-12-18],
            strike: 235.0,
            first_seen_at: now,
            last_seen_at: now,
            underlying_instrument_id: iwm.id
          }
        ],
        returning: [:id]
      )

    at = DateTime.utc_now()

    Repo.insert_all(Idea, [
      %{
        scanned_on: ~D[2026-10-24],
        list: "dip_buy",
        underlying_instrument_id: iwm.id,
        contract_id: contract_id,
        kind: "call",
        strike: 235.0,
        expiration: ~D[2026-12-18],
        dte: 55,
        spot: 230.5,
        bid: 5.9,
        ask: 6.1,
        delta: 0.42,
        open_interest: 1200,
        iv_pct: 21.4,
        rv_pct: 25.0,
        iv_rv: 0.856,
        breakeven: 241.1,
        breakeven_move_pct: 0.046,
        expected_move_pct: 0.071,
        probability_profit: 0.38,
        lottery: false,
        setup: "RSI(2) 5.1 under 10, 2.3% above the 100-day average",
        score: 1.9,
        status: "new",
        inserted_at: at,
        updated_at: at
      }
    ])

    :ok
  end

  test "the page lists the latest scan's ideas and Analyze fills the form from one", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/options")

    assert html =~ "Oct 24 scan · 1 ideas"
    assert html =~ "IWM $235.00 call"
    assert html =~ "RSI(2) 5.1 under 10"
    assert html =~ "+4.6%"
    refute html =~ "lottery ticket"

    [%Idea{id: id}] = Repo.all(Idea)
    html = view |> element("#idea-#{id} button[phx-click=idea]") |> render_click()
    assert html =~ "Auro is not running."

    # The contract tab holds what was picked, to tweak by hand.
    html = render_patch(view, ~p"/options?view=custom")
    assert html =~ ~s(value="235")
    assert html =~ ~s(value="6.1")
    assert html =~ ~s(value="21.4")

    assert html =~
             ~r/<option[^>]*value="long_call"[^>]*selected|<option[^>]*selected[^>]*value="long_call"/
  end

  test "dismissing an idea takes it off the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")
    [%Idea{id: id}] = Repo.all(Idea)

    html = view |> element("#idea-#{id} button[aria-label=Dismiss]") |> render_click()

    refute html =~ "IWM $235.00 call"
    assert {_, [%Idea{status: "dismissed"}]} = Options.latest_ideas()
  end

  test "with no scan recorded the section says so", %{conn: conn} do
    Repo.delete_all(Idea)
    {:ok, _view, html} = live(conn, ~p"/options")
    assert html =~ "The scan runs on trading days at 9:15 and 10:15 New York"
  end
end
