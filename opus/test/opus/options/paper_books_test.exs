defmodule Opus.Options.PaperBooksTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Options.Idea
  alias Opus.Options.Paper
  alias Opus.Options.Paper.{Event, Position, Trade}
  alias Opus.Repo

  # Captured 14:00 UTC on the 23rd: the 10:00 New York snapshot.
  @captured ~N[2026-10-23 14:00:03]
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

  test "ideas buy the day's dip-buy call once", %{qqq: qqq, ids: ids} do
    Repo.insert!(%Idea{
      scanned_on: ~D[2026-10-23],
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

  test "half at double: two calls bought, one sold at double, the rest rides",
       %{conn: conn, qqq: qqq, ids: ids} do
    call = ids[{"call", 650.0}]

    Repo.insert!(%Idea{
      scanned_on: ~D[2026-10-23],
      list: "dip_buy",
      underlying_instrument_id: qqq.id,
      contract_id: call,
      kind: "call",
      strike: 650.0,
      expiration: @expiry,
      dte: 42,
      spot: @spot,
      setup: "RSI(2) 4"
    })

    assert {:ok, [{:open, "long_call", [%{quantity: 2, open_price: 6.12}]}]} =
             Paper.run("ideas_half", "QQQ")

    assert_in_delta book_cash("ideas_half"), 100_000.0 - 1_224.0 - 0.2, 1.0e-6
    assert book_cash("ideas") == 100_000.0

    # A week later the call bids 12.50, more than double the 6.12 paid.
    Repo.insert_all("option_quotes", [
      %{
        ticker: "Q",
        captured_at: ~N[2026-10-30 14:00:03],
        source: "questrade",
        spot: 640.0,
        bid: 12.5,
        ask: 12.7,
        delta: 0.6,
        contract_id: call
      }
    ])

    assert {:ok, [{:sell_half, _trade, _leg, 12.5}]} = Paper.run("ideas_half", "QQQ")

    assert [%{status: "closed", quantity: 1, close_price: 12.5}, %{status: "open", quantity: 1}] =
             Position |> Repo.all() |> Enum.sort_by(&(&1.status != "closed"))

    assert [%Trade{status: "open"}] = Repo.all(Trade)
    # The half sold brings in 1,250 less its commission: more than the 1,224 both cost.
    assert_in_delta book_cash("ideas_half"), 100_000.0 - 1_224.0 - 0.2 + 1_250.0 - 0.1, 1.0e-6

    [trade] = Paper.book("ideas_half").trades
    # The rest is marked at the 12.60 mid.
    assert_in_delta trade.pnl, -1_224.2 + 1_249.9 + 1_260.0, 1.0e-6

    {:ok, _view, html} = live(conn, ~p"/options?view=paper&book=ideas_half&trade=#{trade.id}")
    assert html =~ "half was sold at double"
  end

  defp quote_at(captured_at, contract_id, bid, ask, spot \\ @spot) do
    Repo.insert_all("option_quotes", [
      %{
        ticker: "Q",
        captured_at: captured_at,
        source: "questrade",
        spot: spot,
        bid: bid,
        ask: ask,
        delta: 0.0,
        contract_id: contract_id
      }
    ])
  end

  test "an intraday quote that reaches the take-profit fills it, like a resting order",
       %{ids: ids} do
    {:ok, _} = Paper.run("put_spread", "QQQ")
    assert Paper.open_contracts() == %{"QQQ" => [ids[{"put", 560.0}], ids[{"put", 590.0}]]}

    # 11:00 New York: not there yet (3.05 − 1.00 = 2.05 to close, the target is 1.47).
    quote_at(~N[2026-10-23 15:00:00], ids[{"put", 590.0}], 3.0, 3.05, 625.0)
    quote_at(~N[2026-10-23 15:00:00], ids[{"put", 560.0}], 1.0, 1.04, 625.0)
    assert [] = Paper.take_profits(~U[2026-10-23 15:01:00Z])

    # The book is priced at that quote, not this morning's.
    book = Paper.book("put_spread")
    assert book.priced_at == ~N[2026-10-23 15:00:00.000000]
    [trade] = book.trades
    assert trade.spot == 625.0

    # 14:15: 1.05 − 0.50 = 0.55 to close: filled then.
    quote_at(~N[2026-10-23 18:15:00], ids[{"put", 590.0}], 1.0, 1.05, 640.0)
    quote_at(~N[2026-10-23 18:15:00], ids[{"put", 560.0}], 0.5, 0.52, 640.0)

    assert [{"put_spread", _id, [{:close, _trade, fills}]}] =
             Paper.take_profits(~U[2026-10-23 18:16:00Z])

    assert Enum.sort(Enum.map(fills, &elem(&1, 1))) == [0.5, 1.05]
    assert [%Trade{status: "closed", closed_on: ~D[2026-10-23]}] = Repo.all(Trade)
    assert Paper.open_contracts() == %{}
  end

  test "the wheel's put is bought back intraday at half its premium", %{ids: ids} do
    assert {:ok, [{:open, %{strike: 590.0, bid: 5.0}}]} = Paper.run("wheel", "QQQ")

    quote_at(~N[2026-10-23 17:00:00], ids[{"put", 590.0}], 2.3, 2.4, 650.0)

    assert [{"wheel", _id, [{:close, %{strike: 590.0}, 2.4}]}] =
             Paper.take_profits(~U[2026-10-23 17:05:00Z])

    assert [%Position{status: "closed", close_price: 2.4}] = Repo.all(Position)
  end

  test "take-profits wait for the day's check, which places the orders", %{ids: ids} do
    {:ok, _} = Paper.run("put_spread", "QQQ")

    # Monday the 26th: a quote that would fill, but the book hasn't run that day.
    quote_at(~N[2026-10-26 15:00:00], ids[{"put", 590.0}], 1.0, 1.05)
    quote_at(~N[2026-10-26 15:00:00], ids[{"put", 560.0}], 0.5, 0.52)
    assert [] = Paper.take_profits(~U[2026-10-26 15:01:00Z])
    assert [%Trade{status: "open"}] = Repo.all(Trade)
  end

  test "a spread still open at expiry settles each leg at the expiry-day close",
       %{qqq: qqq, ids: ids} do
    {:ok, _} = Paper.run("put_spread", "QQQ")

    # The Monday after a Friday expiry: QQQ has bounced to 640 by the run,
    # but the spread settles on Friday's close of 570, between the strikes.
    Repo.insert_all("option_quotes", [
      %{
        ticker: "Q",
        captured_at: ~N[2026-12-07 15:00:03],
        source: "questrade",
        spot: 640.0,
        bid: 0.0,
        ask: 0.05,
        delta: 0.0,
        contract_id: ids[{"put", 590.0}]
      }
    ])

    # No close stored yet: it waits.
    assert {:ok, [{:hold, _trade}]} = Paper.run("put_spread", "QQQ")
    Repo.delete_all(from(e in Event, where: e.on == ^~D[2026-12-07]))

    Repo.insert_all("candles", [
      %{
        instrument_id: qqq.id,
        instrument: "QQQ",
        granularity: "D",
        timestamp: ~U[2026-12-04 05:00:00Z],
        open: 575.0,
        high: 578.0,
        low: 566.0,
        close: 570.0,
        volume: 1,
        complete: true
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
    assert html =~ "Priced at 10:00 New York"
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
