defmodule Opus.Accounts.SnapshotsTest do
  use Opus.DataCase, async: false

  alias Opus.Accounts.Snapshots

  setup do
    Repo.query!("DELETE FROM wealthsimple_positions")
    Repo.query!("DELETE FROM holding_snapshots")

    %{rows: [[account]]} =
      Repo.query!(
        "INSERT INTO wealthsimple_accounts (account_type, currency) VALUES ('Non-registered', 'CAD') RETURNING id"
      )

    Repo.query!(
      "INSERT INTO wealthsimple_positions (account_id, symbol, shares, avg_cost, current_price) " <>
        "VALUES ($1, 'FLT.TO', 200, 0.69, 0.485), ($1, 'PNG.VN', 50, 8.05, 3.78)",
      [account]
    )

    :ok
  end

  defp price!(symbol, price),
    do:
      Repo.query!("UPDATE wealthsimple_positions SET current_price = $2 WHERE symbol = $1", [
        symbol,
        price
      ])

  test "each close is recorded once, a re-run replacing it" do
    today = Opus.Clock.today()
    assert Snapshots.take(today) == 2
    price!("FLT.TO", 0.5)
    assert Snapshots.take(today) == 2

    assert [%{on: ^today, value: value, cost: cost}] = Snapshots.history()
    assert_in_delta value, 200 * 0.5 + 50 * 3.78, 1.0e-9
    assert_in_delta cost, 200 * 0.69 + 50 * 8.05, 1.0e-9
  end

  test "net worth records real accounts only, CAD added up by close" do
    Repo.query!("DELETE FROM account_values")
    today = Opus.Clock.today()

    accounts = [
      %{
        key: "questrade-1",
        broker: "Questrade",
        label: "TFSA",
        currency: "CAD",
        value: 1000.0,
        paper: false
      },
      %{
        key: "oanda-1",
        broker: "OANDA",
        label: "Practice",
        currency: "CAD",
        value: 100_000.0,
        paper: true
      },
      %{
        key: "ws-2",
        broker: "Wealthsimple",
        label: "USD",
        currency: "USD",
        value: 50.0,
        paper: false
      }
    ]

    assert Snapshots.take_accounts(today, accounts) == 2
    assert [%{on: ^today, value: 1000.0}] = Snapshots.net_worth()
  end

  test "the history gives the day's move, the fall from the high and the worst" do
    today = Opus.Clock.today()

    for {offset, flt} <- [{-3, 0.6}, {-2, 0.8}, {-1, 0.4}] do
      price!("FLT.TO", flt)
      Snapshots.take(Date.add(today, offset))
    end

    price!("FLT.TO", 0.5)
    Snapshots.take(today)

    # Values: 309, 349, 269, 289 (PNG.VN at 189 throughout).
    s = Snapshots.history() |> Snapshots.summary()
    assert s.on == today
    assert_in_delta s.day_change, 20.0, 1.0e-9
    assert_in_delta s.drawdown, 1 - 289 / 349, 1.0e-9
    assert_in_delta s.worst_drawdown, 1 - 269 / 349, 1.0e-9

    assert %{change: change} = Snapshots.change_since(Date.add(today, -2))
    assert_in_delta change, 289 - 309, 1.0e-9
    assert Snapshots.summary([]) == nil
  end
end
