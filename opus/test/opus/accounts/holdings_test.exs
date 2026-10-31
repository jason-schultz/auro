defmodule Opus.Accounts.HoldingsTest do
  use ExUnit.Case, async: true

  alias Opus.Accounts.Holdings

  @stored [
    %{
      "id" => 16,
      "account_type" => "LIRA",
      "account_number" => "WK3HQ9MN0CAD",
      "currency" => "CAD",
      "cash" => nil,
      "market_value" => 193_464.73,
      "positions" => []
    },
    %{
      "id" => 18,
      "account_type" => "Non-registered",
      "account_number" => nil,
      "currency" => "CAD",
      "cash" => 12.5,
      "market_value" => nil,
      "positions" => [
        %{"symbol" => "FLT.TO", "shares" => 200.0, "avg_cost" => 0.69, "current_price" => 0.485}
      ]
    }
  ]

  test "the stored accounts round-trip through the editor, keeping each holding's latest price" do
    draft = Holdings.draft(@stored)
    assert [%{"market_value" => "193464.73"}, %{"cash" => "12.5", "positions" => [flt]}] = draft
    assert flt == %{"symbol" => "FLT.TO", "shares" => "200", "avg_cost" => "0.69"}

    assert {:ok, [lira, nonreg]} = Holdings.payload(draft, @stored)
    assert %{account_number: "WK3HQ9MN0CAD", market_value: 193_464.73, positions: []} = lira

    assert %{cash: 12.5, market_value: nil, total_equity: nil, positions: [position]} = nonreg
    assert position == %{symbol: "FLT.TO", shares: 200.0, avg_cost: 0.69, current_price: 0.485}
  end

  test "the form's params read back in order; blank holding rows are dropped" do
    params = %{
      "accounts" => %{
        "1" => %{
          "account_type" => "TFSA",
          "account_number" => "",
          "currency" => "CAD",
          "cash" => "1,000",
          "positions" => %{
            "1" => %{"symbol" => "", "shares" => "", "avg_cost" => ""},
            "0" => %{"symbol" => "png.vn", "shares" => "50", "avg_cost" => "$8.05"}
          }
        },
        "0" => Map.put(Holdings.blank_account(), "account_type", "RRSP")
      }
    }

    draft = Holdings.from_params(params)
    assert Enum.map(draft, & &1["account_type"]) == ["RRSP", "TFSA"]

    assert {:ok, [_rrsp, tfsa]} = Holdings.payload(draft, [])
    assert %{account_number: nil, cash: 1000.0, positions: [png]} = tfsa
    assert png == %{symbol: "PNG.VN", shares: 50.0, avg_cost: 8.05, current_price: nil}
  end

  test "a number that doesn't read, or no shares, says which account and holding" do
    bad_cash = [%{Holdings.blank_account() | "cash" => "12abc"}]

    assert {:error, "Account 1 (TFSA): cash isn't a number: 12abc"} =
             Holdings.payload(bad_cash, [])

    no_shares = [
      %{
        Holdings.blank_account()
        | "positions" => [%{"symbol" => "SPY", "shares" => "0", "avg_cost" => ""}]
      }
    ]

    assert {:error, "Account 1 (TFSA), SPY: shares must be more than 0."} =
             Holdings.payload(no_shares, [])
  end

  describe "apply_fill/3" do
    @draft [
      %{"account_type" => "TFSA", "cash" => "1000", "positions" => []},
      %{
        "account_type" => "Non-registered",
        "cash" => "25",
        "positions" => [%{"symbol" => "SPY", "shares" => "10", "avg_cost" => "100"}]
      }
    ]

    defp fill(side, shares, price, cash),
      do: %{side: side, symbol: "spy", shares: shares, price: price, cash: cash}

    test "a buy of something new adds it and spends the cash" do
      assert {:ok, [tfsa, _]} =
               Holdings.apply_fill(@draft, "TFSA", fill("buy", 4.0, 120.0, -480.0))

      assert tfsa["cash"] == "520"
      assert tfsa["positions"] == [%{"symbol" => "SPY", "shares" => "4", "avg_cost" => "120"}]
    end

    test "a buy of something held blends the average cost" do
      assert {:ok, [_, nr]} =
               Holdings.apply_fill(@draft, "Non-registered", fill("buy", 10.0, 120.0, -1200.0))

      assert [%{"shares" => "20", "avg_cost" => "110"}] = nr["positions"]
      assert nr["cash"] == "-1175"
    end

    test "a sale takes the shares off, and the holding when none are left" do
      assert {:ok, [_, nr]} =
               Holdings.apply_fill(@draft, "Non-registered", fill("sell", 4.0, 130.0, 520.0))

      assert [%{"shares" => "6", "avg_cost" => "100"}] = nr["positions"]
      assert nr["cash"] == "545"

      assert {:ok, [_, %{"positions" => []}]} =
               Holdings.apply_fill(@draft, "Non-registered", fill("sell", 10.0, 130.0, 1300.0))
    end

    test "a sale past what's held, or an account that isn't there, says so" do
      assert {:error, "Non-registered holds 10 SPY; the sale is 11."} =
               Holdings.apply_fill(@draft, "Non-registered", fill("sell", 11.0, 1.0, 11.0))

      assert {:error, "There's no RRSP account on the Accounts page."} =
               Holdings.apply_fill(@draft, "RRSP", fill("buy", 1.0, 1.0, -1.0))
    end
  end
end
