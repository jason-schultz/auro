defmodule Opus.Options.PaperTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Options.Paper
  alias Opus.Options.Paper.{Event, Position, Trade}
  alias Opus.Repo

  # Captured 02:00 UTC on the 24th: the closing quotes of the 23rd.
  @captured ~N[2026-10-24 02:00:03]
  @expiry ~D[2026-12-04]

  setup do
    for table <- [Event, Position, Trade, "option_quotes", "option_contracts"],
        do: Repo.delete_all(table)

    {:ok, spy} = Instruments.add("SPY", "etf")

    contracts =
      for {kind, strike} <- [{"put", 590.0}, {"put", 600.0}, {"call", 640.0}] do
        %{
          ticker: "x#{kind}#{trunc(strike)}",
          underlying: "SPY",
          contract_type: kind,
          expiration_date: @expiry,
          strike: strike,
          first_seen_at: @captured,
          last_seen_at: @captured,
          underlying_instrument_id: spy.id
        }
      end

    {_, rows} = Repo.insert_all("option_contracts", contracts, returning: [:id, :strike])

    deltas = %{590.0 => -0.25, 600.0 => -0.35, 640.0 => 0.25}

    quotes =
      for %{id: id, strike: strike} <- rows do
        %{
          ticker: "x",
          captured_at: @captured,
          source: "questrade",
          spot: 615.0,
          bid: 4.0,
          ask: 4.1,
          delta: deltas[strike],
          contract_id: id
        }
      end

    Repo.insert_all("option_quotes", quotes)
    :ok
  end

  test "sells the put once per market day, however often it runs" do
    assert Paper.market_date(@captured) == ~D[2026-10-23]
    assert {:ok, [{:open, %{strike: 590.0}}]} = Paper.run_underlying("SPY")
    assert {:skipped, :already_ran} = Paper.run_underlying("SPY")

    assert [%Position{kind: "put", strike: 590.0, open_price: 4.0, status: "open"}] =
             Repo.all(Position)

    assert ["mark", "open"] = Event |> Repo.all() |> Enum.map(& &1.kind) |> Enum.sort()

    book = Paper.book()
    assert book.cash == 100_000.0 + 400.0 - 0.1
    assert book.premium == 400.0
    assert [%{mark: 4.05}] = book.legs
    assert book.started_on == ~D[2026-10-23]
  end

  test "an underlying with no stored chain is skipped" do
    assert {:skipped, :no_snapshot} = Paper.run_underlying("IWM")
  end

  test "the paper book has its own tab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/options")
    assert html =~ "Paper book"
    refute html =~ "the first trades open at the next 10:30"

    # The tab opens on all five books side by side.
    html = view |> element("nav a", "Paper book") |> render_click()
    assert_patch(view, ~p"/options?view=paper")
    assert html =~ "All books"
    assert html =~ "not started"

    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=wheel")
    assert html =~ "the first trades open at the next 10:30"

    Paper.run_underlying("SPY")
    {:ok, _view, html} = live(conn, ~p"/options?view=paper")
    assert html =~ "1 open"
    assert html =~ "Too early to judge"

    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=wheel")
    assert html =~ "SPY wheel"

    # The book opens on the overview: one row per trade.
    assert html =~ "Room before the strike"
    assert html =~ "SPY wheel"

    # A trade shows its cycle and its current leg, with the rules spelled
    # out; the payoff chart needs the engine, which tests can't reach.
    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=wheel&trade=SPY")
    assert html =~ "Premium collected"
    assert html =~ "What happens next"
    assert html =~ "effective cost"
    assert html =~ "If it goes well"
    assert html =~ "If it goes wrong"
    assert html =~ "34% (Covid)"
    assert html =~ "needs the engine"

    [leg] = Paper.book().legs
    detail = Paper.leg(leg.position.id)
    assert detail.take_profit_price == leg.position.open_price / 2
    assert detail.manage_on == Date.add(leg.position.expiration, -21)
    assert [%{mid: _}] = detail.marks
    assert Paper.leg(-1) == nil
    assert html =~ "Net premium sold"
  end
end
