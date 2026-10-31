defmodule Opus.Accounts.OverviewTest do
  use ExUnit.Case, async: true

  alias Opus.Accounts.Overview

  # Shapes mirror Rust's `GET /api/brokers` and `GET /api/brokers/wealthsimple`.
  @brokers [
    %{
      "broker" => "oanda",
      "display_name" => "OANDA",
      "connected" => true,
      "accounts" => [
        %{
          "id" => "101-002-39023567-001",
          "name" => "Practice (101-002-39023567-001)",
          "account_type" => "Practice",
          "currency" => "CAD",
          "cash" => 87_245.87,
          "market_value" => nil,
          "total_equity" => 87_245.87,
          "buying_power" => 87_000.0
        }
      ]
    },
    %{
      "broker" => "questrade",
      "display_name" => "Questrade",
      "connected" => true,
      "accounts" => [
        %{
          "id" => "52436439",
          "name" => "TFSA (52436439)",
          "account_type" => "TFSA",
          "currency" => "CAD",
          "cash" => 250.29,
          "market_value" => 0.0,
          "total_equity" => 250.29,
          "buying_power" => 250.28
        }
      ]
    },
    %{
      "broker" => "wealthsimple",
      "display_name" => "Wealthsimple",
      "connected" => true,
      "accounts" => [
        %{
          "id" => "1",
          "name" => "LIRA (WK3HQ9MN0CAD)",
          "account_type" => "LIRA",
          "currency" => "CAD",
          "cash" => nil,
          "market_value" => 193_464.73,
          "total_equity" => nil,
          "buying_power" => nil
        },
        %{
          "id" => "3",
          "name" => "Non-registered",
          "account_type" => "Non-registered",
          "currency" => "CAD",
          "cash" => nil,
          "market_value" => 286.0,
          "total_equity" => nil,
          "buying_power" => nil
        }
      ]
    }
  ]

  @wealthsimple [
    %{"id" => 1, "account_type" => "LIRA", "positions" => []},
    %{
      "id" => 3,
      "account_type" => "Non-registered",
      "positions" => [
        %{"symbol" => "HODL.CN", "shares" => 100, "avg_cost" => 1.90, "current_price" => 1.86},
        %{"symbol" => "FLT.TO", "shares" => 200, "avg_cost" => 0.69, "current_price" => 0.50}
      ]
    }
  ]

  test "totals CAD accounts and orders them by value with shares summing to one" do
    overview = Overview.build(@brokers, @wealthsimple)

    assert_in_delta overview.total_cad, 281_246.89, 0.01

    assert Enum.map(overview.accounts, & &1.label) == [
             "LIRA",
             "Practice",
             "Non-registered",
             "TFSA"
           ]

    assert_in_delta Enum.sum(Enum.map(overview.accounts, & &1.share)), 1.0, 1.0e-9
    assert Enum.map(overview.accounts, & &1.rank) == [0, 1, 2, 3]
    assert overview.offline == []
  end

  test "labels live brokers with their id and Wealthsimple with the number from its name" do
    overview = Overview.build(@brokers, @wealthsimple)
    by_label = Map.new(overview.accounts, &{&1.label, &1})

    assert %{source: :live, broker: "OANDA", number: "101-002-39023567-001", cash: 87_245.87} =
             by_label["Practice"]

    assert %{source: :manual, broker: "Wealthsimple", number: "WK3HQ9MN0CAD", cash: nil} =
             by_label["LIRA"]

    assert by_label["Non-registered"].number == nil
  end

  test "values an account from cash plus market value when total equity is missing" do
    overview = Overview.build(@brokers, @wealthsimple)
    lira = Enum.find(overview.accounts, &(&1.label == "LIRA"))

    assert_in_delta lira.value, 193_464.73, 0.001
  end

  test "builds one positions table per Wealthsimple account that has positions" do
    overview = Overview.build(@brokers, @wealthsimple)

    assert [%{account: "Non-registered", rows: [flt, hodl]}] = overview.positions
    assert flt.symbol == "FLT.TO"
    assert_in_delta flt.value, 100.0, 0.001
    assert_in_delta flt.gain, -38.0, 0.001
    assert hodl.symbol == "HODL.CN"
    assert_in_delta hodl.gain, -4.0, 0.001
  end

  test "says when the table's prices are from: the latest re-price" do
    priced = [
      %{
        "id" => 2,
        "account_type" => "Non-registered",
        "positions" => [
          %{"symbol" => "FLT.TO", "shares" => 200, "updated_at" => "2026-10-29T19:45:01Z"},
          %{"symbol" => "PNG.VN", "shares" => 50, "updated_at" => "2026-10-29T20:00:02Z"}
        ]
      }
    ]

    assert [%{priced_at: ~U[2026-10-29 20:00:02Z]}] = Overview.build(@brokers, priced).positions
    assert [%{priced_at: nil}] = Overview.build(@brokers, @wealthsimple).positions
  end

  test "falls back to average cost when a position has never been priced" do
    unpriced = [
      %{
        "id" => 3,
        "account_type" => "Non-registered",
        "positions" => [
          %{"symbol" => "PNG.VN", "shares" => 50, "avg_cost" => 4.05, "current_price" => nil}
        ]
      }
    ]

    assert [%{rows: [row]}] = Overview.build(@brokers, unpriced).positions
    assert row.price == 4.05
    assert_in_delta row.value, 202.5, 0.001
    assert_in_delta row.gain, 0.0, 0.001
  end

  test "lists a disconnected broker as offline and leaves its accounts out" do
    offline =
      put_in(Enum.at(@brokers, 1), ["connected"], false) |> Map.put("error", "token expired")

    brokers = List.replace_at(@brokers, 1, offline)

    overview = Overview.build(brokers, @wealthsimple)

    refute Enum.any?(overview.accounts, &(&1.broker == "Questrade"))
    assert overview.offline == [%{broker: "Questrade", error: "token expired"}]
  end

  test "lists a non-CAD account without a share and outside the total" do
    usd = put_in(Enum.at(@brokers, 1), ["accounts", Access.at(0), "currency"], "USD")
    brokers = List.replace_at(@brokers, 1, usd)

    overview = Overview.build(brokers, @wealthsimple)
    tfsa = Enum.find(overview.accounts, &(&1.label == "TFSA"))

    assert tfsa.share == nil
    assert_in_delta overview.total_cad, 281_246.89 - 250.29, 0.01
  end

  test "handles no brokers at all" do
    assert %{total_cad: +0.0, accounts: [], positions: [], offline: []} = Overview.build([], [])
  end

  test "a hand-entered account moves with its holdings' latest prices, not a typed total" do
    # The typed holdings value (286) is stale; the holdings re-priced to 300.
    repriced =
      put_in(@wealthsimple, [Access.at(1), "positions"], [
        %{"symbol" => "HODL.CN", "shares" => 100, "avg_cost" => 1.90, "current_price" => 2.0},
        %{"symbol" => "FLT.TO", "shares" => 200, "avg_cost" => 0.69, "current_price" => 0.5}
      ])

    by_label = Map.new(Overview.build(@brokers, repriced).accounts, &{&1.label, &1})
    assert_in_delta by_label["Non-registered"].value, 300.0, 1.0e-9
  end

  test "a paper account is listed and totalled apart, never in the real total" do
    paper =
      Enum.map(@brokers, fn
        %{"broker" => "oanda"} = b ->
          update_in(b, ["accounts"], fn accounts ->
            Enum.map(accounts, &Map.put(&1, "paper", true))
          end)

        b ->
          b
      end)

    real = Overview.build(@brokers, @wealthsimple)
    split = Overview.build(paper, @wealthsimple)
    practice = Enum.find(split.accounts, &(&1.label == "Practice"))

    assert practice.paper
    assert practice.share == nil
    assert_in_delta split.paper_cad, practice.value, 1.0e-9
    assert_in_delta split.total_cad, real.total_cad - practice.value, 1.0e-6
    assert_in_delta split.accounts |> Enum.map(&(&1.share || 0)) |> Enum.sum(), 1.0, 1.0e-9
  end
end
