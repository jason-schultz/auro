defmodule Opus.Options.PaperBooksTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Options.Idea
  alias Opus.Options.Paper
  alias Opus.Options.Paper.{Event, Position, Trade}
  alias Opus.Repo

  # Captured 02:00 UTC on the 24th: the closing quotes of the 23rd.
  @captured ~N[2026-10-24 02:00:03]
  @expiry ~D[2026-12-04]
  @spot 615.0

  # {kind, strike, delta, bid, ask}
  @chain [
    {"put", 540.0, -0.05, 1.00, 1.04},
    {"put", 560.0, -0.10, 2.00, 2.06},
    {"put", 580.0, -0.16, 3.00, 3.10},
    {"put", 590.0, -0.25, 5.00, 5.10},
    {"call", 640.0, 0.16, 3.00, 3.10},
    {"call", 650.0, 0.40, 6.00, 6.12},
    {"call", 660.0, 0.05, 1.00, 1.04}
  ]

  setup do
    for table <- [Event, Position, Trade, Idea, "option_quotes", "option_contracts"],
        do: Repo.delete_all(table)

    {:ok, qqq} = Instruments.add("QQQ", "etf")

    contracts =
      for {kind, strike, _, _, _} <- @chain do
        %{
          ticker: "Q#{kind}#{trunc(strike)}",
          underlying: "QQQ",
          contract_type: kind,
          expiration_date: @expiry,
          strike: strike,
          first_seen_at: @captured,
          last_seen_at: @captured,
          underlying_instrument_id: qqq.id
        }
      end

    {_, rows} =
      Repo.insert_all("option_contracts", contracts, returning: [:id, :strike, :contract_type])

    ids = Map.new(rows, &{{&1.contract_type, &1.strike}, &1.id})

    Repo.insert_all(
      "option_quotes",
      for {kind, strike, delta, bid, ask} <- @chain do
        %{
          ticker: "Q",
          captured_at: @captured,
          source: "questrade",
          spot: @spot,
          bid: bid,
          ask: ask,
          delta: delta,
          volatility: 20.0,
          contract_id: ids[{kind, strike}]
        }
      end
    )

    %{qqq: qqq, ids: ids}
  end

  defp book_cash(book), do: Paper.book(book).cash

  test "a put credit spread opens both legs once, in its own book" do
    assert {:ok, [{:open, "put_spread", legs}]} = Paper.run("put_spread", "QQQ")
    assert Enum.map(legs, &{&1.side, &1.strike}) == [{"long", 560.0}, {"short", 590.0}]
    assert {:skipped, :already_ran} = Paper.run("put_spread", "QQQ")

    assert [%Trade{structure: "put_spread", strategy: "put_spread", status: "open"}] =
             Repo.all(Trade)

    # Credit 5.00 − 2.06 = 2.94 a share, less two contracts' commission.
    assert_in_delta book_cash("put_spread"), 100_000.0 + 294.0 - 0.2, 1.0e-6
    assert book_cash("wheel") == 100_000.0

    [trade] = Paper.book("put_spread").trades
    assert_in_delta trade.summary.max_loss, 3_000.0 - 294.0, 1.0e-6

    assert ["mark", "mark", "open", "open"] =
             Event |> Repo.all() |> Enum.map(& &1.kind) |> Enum.sort()
  end

  test "an iron condor opens four legs on one expiry" do
    assert {:ok, [{:open, "iron_condor", legs}]} = Paper.run("iron_condor", "QQQ")

    assert Enum.map(legs, &{&1.side, &1.kind, &1.strike}) == [
             {"long", "put", 540.0},
             {"short", "put", 580.0},
             {"short", "call", 640.0},
             {"long", "call", 660.0}
           ]

    [trade] = Paper.book("iron_condor").trades
    assert length(trade.summary.breakevens) == 2
  end

  test "crash puts buy the −0.10 put at the ask" do
    assert {:ok, [{:open, "long_put", [%{strike: 560.0, open_price: 2.06}]}]} =
             Paper.run("crash_puts", "QQQ")

    assert_in_delta book_cash("crash_puts"), 100_000.0 - 206.0 - 0.1, 1.0e-6
  end

  test "ideas buy tonight's dip-buy call once", %{qqq: qqq, ids: ids} do
    Repo.insert!(%Idea{
      scanned_on: ~D[2026-10-24],
      list: "dip_buy",
      underlying_instrument_id: qqq.id,
      contract_id: ids[{"call", 650.0}],
      kind: "call",
      strike: 650.0,
      expiration: @expiry,
      dte: 42,
      spot: @spot,
      setup: "RSI(2) 4"
    })

    assert {:ok, [{:open, "long_call", [%{strike: 650.0, open_price: 6.12}]}]} =
             Paper.run("ideas", "QQQ")

    assert {:skipped, :already_ran} = Paper.run("ideas", "QQQ")
  end

  test "a spread still open at expiry settles each leg at intrinsic", %{ids: ids} do
    {:ok, _} = Paper.run("put_spread", "QQQ")

    # The expiry night's capture: QQQ at 570, between the strikes.
    Repo.insert_all("option_quotes", [
      %{
        ticker: "Q",
        captured_at: ~N[2026-12-05 02:00:03],
        source: "questrade",
        spot: 570.0,
        bid: 20.0,
        ask: 20.5,
        delta: -0.9,
        contract_id: ids[{"put", 590.0}]
      }
    ])

    assert {:ok, [{:settle, _trade, 570.0}]} = Paper.run("put_spread", "QQQ")
    assert [%Trade{status: "closed"}] = Repo.all(Trade)

    # The short 590 put pays its 20 of intrinsic value; the long 560 is worthless.
    expired = Repo.all(from(e in Event, where: e.kind == "expire"))
    assert_in_delta Enum.sum_by(expired, & &1.cash), -2_000.0, 1.0e-6
    assert_in_delta book_cash("put_spread"), 100_000.0 + 294.0 - 0.2 - 2_000.0, 1.0e-6
  end

  test "each book has its own view, with the whole structure for a trade", %{conn: conn} do
    {:ok, _} = Paper.run("put_spread", "QQQ")
    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=put_spread")
    assert html =~ "Put spreads"
    assert html =~ "Where it stands"
    assert html =~ "QQQ"

    [trade] = Paper.book("put_spread").trades
    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=put_spread&trade=#{trade.id}")
    assert html =~ "Max loss"
    assert html =~ "Net credit"
    assert html =~ "If it goes wrong"
    assert html =~ "spread at expiry"
    assert html =~ "needs the engine"

    [leg | _] = trade.legs

    {:ok, _view, html} =
      live(conn, ~p"/options?view=paper&book=put_spread&trade=#{trade.id}&leg=#{leg.id}")

    assert html =~ "Leg P&amp;L"

    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=crash_puts")
    assert html =~ "Doomsday insurance"
    assert html =~ "Nothing yet"
  end
end
