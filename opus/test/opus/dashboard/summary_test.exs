defmodule Opus.Dashboard.SummaryTest do
  use Opus.DataCase, async: false

  alias Opus.Dashboard.Summary
  alias Opus.Instruments
  alias Opus.Options.Paper.{Event, Position, Trade}
  alias Opus.Repo
  alias Opus.Trading.LiveStrategy

  # Friday Oct 30, 16:30 New York.
  @now ~U[2026-10-30 20:30:00Z]
  @strategy_id "bbbbbbbb-0000-0000-0000-000000000002"

  setup do
    Repo.query!("DELETE FROM live_trades")
    for table <- [Event, Position, Trade], do: Repo.delete_all(table)
    Repo.query!("DELETE FROM wealthsimple_positions")
    Repo.delete_all(LiveStrategy)

    Repo.insert!(%LiveStrategy{
      id: @strategy_id,
      strategy_type: "composite",
      instrument: "NAS100_USD",
      granularity: "M5",
      parameters: %{},
      enabled: true,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    :ok
  end

  defp gathered(engine \\ :up),
    do: %{
      input: %{engine: engine},
      books: [%{pnl: 250.0}, %{pnl: -40.0}],
      live: %{open_trades: 2}
    }

  defp closed_live(instrument, direction, pnl, exit_time) do
    Repo.insert_all("live_trades", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        live_strategy_id: Ecto.UUID.dump!(@strategy_id),
        oanda_trade_id: "#{System.unique_integer([:positive])}",
        instrument: instrument,
        direction: direction,
        units: "1",
        status: "closed",
        entry_price: 1.0,
        exit_price: 1.0,
        entry_time: DateTime.add(exit_time, -3600),
        exit_time: exit_time,
        pnl: pnl,
        pnl_percent: pnl / 10_000,
        created_at: exit_time,
        updated_at: exit_time
      }
    ])
  end

  defp closed_option(closed_on) do
    {:ok, spy} = Instruments.add("SPY", "etf")

    trade =
      Repo.insert!(%Trade{
        strategy: "put_spread",
        underlying_instrument_id: spy.id,
        structure: "put_spread",
        opened_on: ~D[2026-10-26],
        closed_on: closed_on,
        status: "closed"
      })

    leg =
      Repo.insert!(%Position{
        trade_id: trade.id,
        underlying_instrument_id: spy.id,
        side: "short",
        kind: "put",
        quantity: 1,
        strike: 265.0,
        expiration: ~D[2026-12-04],
        open_price: 2.64,
        opened_on: ~D[2026-10-26],
        status: "closed",
        closed_on: closed_on
      })

    for {kind, cash} <- [{"open", 155.8}, {"close", -76.2}],
        do:
          Repo.insert!(%Event{
            position_id: leg.id,
            underlying_instrument_id: spy.id,
            strategy: "put_spread",
            on: closed_on,
            kind: kind,
            cash: cash
          })
  end

  test "a quiet day still says so, with what's open and the books' total" do
    {title, lines} = Summary.build(:day, gathered(), [], @now)

    assert title == "Auro day, Oct 30: all quiet"

    assert lines == [
             "Engine: running",
             "**Live (OANDA):** no trades closed. Open now: 2",
             "**Options (paper, US$):** 0 opened, 0 closed. All books so far: +$210.00"
           ]
  end

  test "the day: live closes with the best and worst, options closed, what to look at" do
    closed_live("NAS100_USD", "Long", 151.15, ~U[2026-10-30 18:00:00Z])
    closed_live("SPX500_USD", "Short", -42.5, ~U[2026-10-30 19:00:00Z])
    # Yesterday's close isn't today's.
    closed_live("XAU_USD", "Long", 999.0, ~U[2026-10-29 19:00:00Z])
    closed_option(~D[2026-10-30])

    alert = %{level: :act, title: "OANDA is offline"}
    {title, lines} = Summary.build(:day, gathered(), [alert, %{level: :fyi, title: "x"}], @now)

    assert title == "Auro day, Oct 30: 1 to look at"
    assert "**Live (OANDA):** 2 closed, 1 won, +$108.65 CAD. Open now: 2" in lines
    assert "  Best: NAS100_USD long +$151.15 · worst: SPX500_USD short −$42.50" in lines

    assert "**Options (paper, US$):** 0 opened, 1 closed (+$79.60). All books so far: +$210.00" in lines

    assert "  SPY put spread closed: +$79.60" in lines
    assert Enum.take(lines, -2) == ["**To look at:**", "• OANDA is offline"]
  end

  test "the week runs from Monday, holdings against their cost" do
    closed_live("XAU_USD", "Long", 999.0, ~U[2026-10-27 19:00:00Z])
    closed_live("EUR_USD", "Long", 5.0, ~U[2026-10-23 19:00:00Z])

    {:ok, %{rows: [[account]]}} =
      Repo.query(
        "INSERT INTO wealthsimple_accounts (account_type, currency) VALUES ('tfsa', 'CAD') RETURNING id"
      )

    Repo.query!(
      "INSERT INTO wealthsimple_positions (account_id, symbol, shares, avg_cost, current_price) " <>
        "VALUES ($1, 'FLT.TO', 200, 0.69, 0.485), ($1, 'PNG.VN', 50, 8.05, 3.78)",
      [account]
    )

    {title, lines} = Summary.build(:week, gathered(), [], @now)

    assert title == "Auro week, Oct 26 to Oct 30: all quiet"
    assert "**Live (OANDA):** 1 closed, 1 won, +$999.00 CAD. Open now: 2" in lines
    assert "**Holdings (Wealthsimple):** 2 worth $286.00, −$254.50 (−47.1%) against cost" in lines
  end
end
