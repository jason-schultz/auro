defmodule Opus.Journal.CardsTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Journal.Cards
  alias Opus.Options.Paper.{Event, Position, Trade}
  alias Opus.Trading.LiveStrategy

  @strategy_id "bbbbbbbb-0000-0000-0000-000000000003"

  setup do
    Repo.query!("DELETE FROM live_trades")
    Repo.query!("DELETE FROM account_snapshots")
    for table <- [Event, Position, Trade], do: Repo.delete_all(table)
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

  defp closed_live(pnl, exit_reason, hours_ago) do
    exit_time = DateTime.add(DateTime.utc_now(), -hours_ago * 3600)

    Repo.insert_all("live_trades", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        live_strategy_id: Ecto.UUID.dump!(@strategy_id),
        oanda_trade_id: "#{System.unique_integer([:positive])}",
        instrument: "NAS100_USD",
        direction: "Long",
        units: "1",
        status: "closed",
        entry_price: 1.0,
        exit_price: 1.0,
        entry_time: DateTime.add(exit_time, -600),
        exit_time: exit_time,
        exit_reason: exit_reason,
        pnl: pnl,
        pnl_percent: pnl / 10_000,
        created_at: exit_time,
        updated_at: exit_time
      }
    ])
  end

  defp card(board, title), do: Enum.find(board.cards, &(&1.title == title))

  test "the OANDA tab: 30-day result, how trades end, and the account's line and drop" do
    closed_live(120.0, "StopLoss", 30)
    closed_live(-40.0, "StopLoss", 50)
    closed_live(60.0, ~s|CompositeExit (ports={"na": {"session_close": true}})|, 70)

    for {days_ago, nav} <- [{3, 100_000.0}, {2, 110_000.0}, {1, 99_000.0}] do
      Repo.insert_all("account_snapshots", [
        %{
          timestamp: DateTime.add(DateTime.utc_now(), -days_ago * 86_400),
          nav: nav,
          balance: nav,
          unrealized_pl: 0.0,
          margin_used: 0.0,
          margin_available: nav,
          currency: "CAD",
          open_position_count: 0
        }
      ])
    end

    board = Cards.oanda()
    assert %{value: "+$140.00", note: "3 closed, 66.7% won"} = card(board, "Last 30 days")

    assert %{value: "Stop-loss hit", note: "2 of 3 · End of the trading day 1"} =
             card(board, "How trades end")

    assert length(board.line) == 3
    assert %{value: "10.0%"} = card(board, "Worst drop")
  end

  test "the Options tab: closed trades' result, how they ended, and the running P&L" do
    {:ok, spy} = Instruments.add("SPY", "etf")
    today = Opus.Clock.today()

    for {pnl, offset} <- [{100.0, -2}, {-30.0, -1}] do
      trade =
        Repo.insert!(%Trade{
          strategy: "put_spread",
          underlying_instrument_id: spy.id,
          structure: "put_spread",
          opened_on: Date.add(today, offset - 3),
          closed_on: Date.add(today, offset),
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
          expiration: Date.add(today, 30),
          open_price: 1.0,
          opened_on: trade.opened_on,
          status: "closed",
          commission: 1.5,
          closed_on: trade.closed_on
        })

      Repo.insert!(%Event{
        position_id: leg.id,
        underlying_instrument_id: spy.id,
        strategy: "put_spread",
        on: trade.closed_on,
        kind: "close",
        cash: pnl
      })
    end

    board = Cards.options()
    assert %{value: "+$70.00", note: "2 closed, 1 made money"} = card(board, "Last 30 days")
    assert %{value: "Closed early", note: "2 of 2"} = card(board, "How trades end")
    assert %{value: "$3.00"} = card(board, "Costs")
    assert Enum.map(board.line, & &1.value) == [100.0, 70.0]
    assert %{value: "−$30.00"} = card(board, "Worst drop")
  end
end
