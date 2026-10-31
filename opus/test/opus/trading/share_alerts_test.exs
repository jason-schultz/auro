defmodule Opus.Trading.ShareAlertsTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Trading.{LiveStrategy, Recipe, ShareAlert, ShareAlerts}

  @day ~D[2026-10-30]

  setup do
    Repo.delete_all(ShareAlert)
    Repo.delete_all(LiveStrategy)

    recipe = Repo.insert!(%Recipe{name: "Dip-buy shares", granularity: "D", definition: %{}})

    {:ok, _} =
      Instruments.create(%{
        symbol: "SPY",
        exchange: "US",
        currency: "USD",
        asset_class: "etf",
        questrade_symbol: "SPY"
      })

    shares = assignment(recipe, "SPY", %{"type" => "share_alert", "amount" => 500})
    oanda = assignment(recipe, "SPX500_USD", %{"type" => "oanda"})
    %{shares: shares, oanda: oanda}
  end

  defp assignment(recipe, instrument, action, enabled \\ true) do
    Repo.insert!(%LiveStrategy{
      strategy_type: "composite",
      instrument: instrument,
      instrument_id: if(instrument == "SPY", do: Instruments.id_for("SPY") |> elem(1)),
      granularity: "D",
      parameters: %{},
      enabled: enabled,
      action: action,
      recipe: recipe,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp filled(ls, side, day, opts \\ []) do
    Repo.insert!(%ShareAlert{
      live_strategy_id: ls.id,
      day: day,
      side: side,
      symbol: "SPY",
      currency: "USD",
      price: 100.0,
      stop_price: Keyword.get(opts, :stop, 90.0),
      shares: 5.0,
      status: Keyword.get(opts, :status, "filled"),
      filled_shares: 5.0,
      filled_price: 100.0,
      account: "TFSA"
    })
  end

  test "only switched-on share-alert assignments are checked", %{shares: shares} do
    assert [%{id: id, symbol: "SPY", currency: "USD", amount: 500.0, name: "Dip-buy shares"}] =
             ShareAlerts.assignments()

    assert id == shares.id
  end

  test "a held position is the last fill, when it's a buy", %{shares: ls} do
    assert ShareAlerts.held([ls.id]) == %{}

    filled(ls, "buy", ~D[2026-10-26], stop: 91.0)

    assert %{entry_day: ~D[2026-10-26], stop_price: 91.0, shares: 5.0, account: "TFSA"} =
             ShareAlerts.held([ls.id])[ls.id]

    filled(ls, "sell", ~D[2026-10-28])
    assert ShareAlerts.held([ls.id]) == %{}

    # An alert you didn't act on doesn't change what's held.
    filled(ls, "buy", ~D[2026-10-29], status: "skipped")
    assert ShareAlerts.held([ls.id]) == %{}
  end

  test "buys and sells become the day's alerts; hold, wait and unready don't", %{shares: ls} do
    [assignment] = ShareAlerts.assignments()

    decisions = [
      %{"id" => ls.id, "action" => "buy", "price" => 120.0, "stop_price" => 110.0},
      %{"id" => Ecto.UUID.generate(), "action" => "buy", "price" => 1.0, "stop_price" => 0.5}
    ]

    assert {[
              {%ShareAlert{
                 side: "buy",
                 shares: 4.0,
                 price: 120.0,
                 stop_price: 110.0,
                 status: "open"
               }, ^assignment}
            ], []} =
             ShareAlerts.record(decisions, [assignment], %{}, @day)

    # A second check the same day keeps the first alert.
    assert {[], []} = ShareAlerts.record(decisions, [assignment], %{}, @day)
    assert Repo.aggregate(ShareAlert, :count) == 1

    assert {[], [{^assignment, "needs 101 daily bars, has 3"}]} =
             ShareAlerts.record(
               [%{"id" => ls.id, "action" => "unready", "why" => "needs 101 daily bars, has 3"}],
               [assignment],
               %{},
               Date.add(@day, 1)
             )

    assert {[], []} =
             ShareAlerts.record(
               [%{"id" => ls.id, "action" => "hold", "price" => 1.0, "stop_price" => 1.0}],
               [assignment],
               %{},
               Date.add(@day, 2)
             )
  end

  test "a sell is for the shares held, with its reason", %{shares: ls} do
    [assignment] = ShareAlerts.assignments()

    held = %{
      ls.id => %{entry_day: ~D[2026-10-20], stop_price: 90.0, shares: 7.0, account: "TFSA"}
    }

    assert {[{%ShareAlert{side: "sell", shares: 7.0, reason: "time_stop"} = alert, _}], []} =
             ShareAlerts.record(
               [%{"id" => ls.id, "action" => "sell", "price" => 101.0, "reason" => "time_stop"}],
               [assignment],
               held,
               @day
             )

    assert ShareAlerts.line(alert, "Dip-buy") =~
             "SELL 7 SPY at about $101.00 US, limit $100.80 US (Dip-buy): held as many days"
  end

  test "an alert not logged by the next check counts as not traded", %{shares: ls} do
    filled(ls, "buy", ~D[2026-10-29], status: "open")
    filled(ls, "buy", @day, status: "open")

    assert ShareAlerts.skip_unlogged(@day) == 1
    assert [%{alert: %ShareAlert{day: @day}, name: "Dip-buy shares"}] = ShareAlerts.open()
  end

  test "Didn't trade takes an alert off the list", %{shares: ls} do
    alert = filled(ls, "buy", @day, status: "open")
    assert {:ok, %ShareAlert{status: "skipped"}} = ShareAlerts.skip(alert.id)
    assert ShareAlerts.open() == []
    assert {:error, _} = ShareAlerts.skip(alert.id)
  end

  test "a log that doesn't read says why and leaves the alert open", %{shares: ls} do
    alert = filled(ls, "buy", @day, status: "open")

    good = %{
      "account" => "TFSA",
      "shares" => "5",
      "price" => "100",
      "cash" => "-500",
      "filled_at" => "2026-10-30T13:50"
    }

    assert {:error, "Pick the account it was filled in."} =
             ShareAlerts.log_fill(alert.id, %{good | "account" => ""})

    assert {:error, "Shares must be more than 0."} =
             ShareAlerts.log_fill(alert.id, %{good | "shares" => "0"})

    assert {:error, "When it filled isn't a date and time: soon"} =
             ShareAlerts.log_fill(alert.id, %{good | "filled_at" => "soon"})

    # The engine isn't reachable in tests: the holdings can't be saved, so
    # the alert isn't marked filled.
    assert {:error, _} = ShareAlerts.log_fill(alert.id, good)
    assert Repo.get!(ShareAlert, alert.id).status == "open"
  end

  test "the form starts from the alert: buys in Non-registered, sells where it was bought", %{
    shares: ls
  } do
    buy = filled(ls, "buy", ~D[2026-10-26], status: "open")
    form = ShareAlerts.form_defaults(buy, ["TFSA", "Non-registered"])

    assert %{"account" => "Non-registered", "shares" => "5", "price" => "100", "cash" => "-500"} =
             form

    assert form["filled_at"] =~ "2026-10-26T"

    filled(ls, "buy", ~D[2026-10-27])
    sell = %{buy | side: "sell", day: @day}

    assert %{"account" => "TFSA", "cash" => "500"} =
             ShareAlerts.form_defaults(sell, ["TFSA", "Non-registered"])
  end

  test "an amount buys whole shares, or a fraction when less than one" do
    assert ShareAlerts.buy_shares(500, 120.0) == 4.0
    assert ShareAlerts.buy_shares(500, 600.0) == 0.8333
    assert ShareAlerts.buy_shares(nil, 600.0) == 0.0
  end

  test "a market tested as shares held goes live as share alerts" do
    {:ok, _} =
      Instruments.create(%{
        symbol: "SPX500_USD",
        exchange: "OANDA",
        currency: "USD",
        asset_class: "index",
        oanda_symbol: "SPX500_USD"
      })

    Repo.query!("UPDATE instruments SET test_broker = 'wealthsimple' WHERE symbol = 'SPY'")
    Repo.query!("UPDATE instruments SET test_broker = 'oanda' WHERE symbol = 'SPX500_USD'")

    assert ShareAlerts.action_for("SPY") == %{type: "share_alert", amount: 500.0}
    assert ShareAlerts.action_for("SPX500_USD") == nil
    assert ShareAlerts.action_for("NOPE") == nil
  end

  test "the amount per buy can be changed, only on a share-alert assignment", %{
    shares: shares,
    oanda: oanda
  } do
    assert {:ok, 750.0} = ShareAlerts.set_amount(shares.id, "$750")
    assert [%{amount: 750.0}] = ShareAlerts.assignments()
    assert {:error, "The amount must be more than 0."} = ShareAlerts.set_amount(shares.id, "0")

    assert {:error, "That strategy doesn't send share alerts."} =
             ShareAlerts.set_amount(oanda.id, "10")
  end
end
