defmodule Opus.MarketData.DividendRecordWorkerTest do
  use ExUnit.Case, async: true

  alias Opus.MarketData.DividendRecordWorker

  test "Questrade's latest dividend becomes a row; none, or no ex-date, is skipped" do
    symbols = [
      %{
        "requested" => "XIU.TO",
        "dividend" => 0.27,
        "ex_date" => "2026-09-26T00:00:00.000000-04:00",
        "dividend_date" => "2026-10-02T00:00:00.000000-04:00"
      },
      %{"requested" => "SDE.TO", "dividend" => 0.0, "ex_date" => nil},
      %{"requested" => "HUT.TO", "dividend" => 0.1, "ex_date" => nil},
      %{"requested" => "NOT.MINE", "dividend" => 1.0, "ex_date" => "2026-09-01T00:00:00Z"}
    ]

    markets = %{"XIU.TO" => 313, "SDE.TO" => 221, "HUT.TO" => 9}

    assert [row] = DividendRecordWorker.rows(symbols, markets, ~U[2026-10-30 23:00:00.123Z])

    assert %{
             instrument_id: 313,
             ex_date: ~D[2026-09-26],
             pay_date: ~D[2026-10-02],
             cash_amount: 0.27
           } = row
  end
end
