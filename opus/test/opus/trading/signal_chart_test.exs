defmodule Opus.Trading.SignalChartTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.SignalChart

  @definition %{
    "components" => %{
      "r" => %{
        "type" => "RsiReversion",
        "params" => %{"rsi_period" => 2, "oversold" => 20, "overbought" => 80}
      },
      "t" => %{"type" => "MaFilter", "params" => %{"period" => 100, "ma_type" => "sma"}}
    },
    "entry" => %{"long" => %{"and" => ["r.long", "t.above"]}},
    "exit" => %{"long" => "r.exit_long"}
  }

  defp bar(day, ports),
    do: %{
      "time" => "2026-10-0#{day}T20:00:00Z",
      "open" => 100.0,
      "high" => 101.0,
      "low" => 99.0,
      "close" => 100.0 + day,
      "ports" => ports
    }

  # The engine's preview body: a buy on day 2, its sell on day 4, and a
  # second buy on day 5 still open at the end.
  defp body do
    %{
      "bars" => [
        bar(1, %{"r.long" => false, "t.above" => true, "r.exit_long" => true}),
        bar(2, %{"r.long" => true, "t.above" => true, "r.exit_long" => false}),
        bar(3, %{"r.long" => true, "t.above" => true, "r.exit_long" => false}),
        bar(4, %{"r.long" => false, "t.above" => true, "r.exit_long" => true}),
        bar(5, %{"r.long" => true, "t.above" => true, "r.exit_long" => false})
      ],
      "signals" => [
        %{
          "time" => "2026-10-02T20:00:00Z",
          "kind" => "entry",
          "direction" => "long",
          "price" => 102.0
        },
        %{
          "time" => "2026-10-04T20:00:00Z",
          "kind" => "exit",
          "direction" => "long",
          "price" => 104.04,
          "reason" => "rule"
        },
        %{
          "time" => "2026-10-05T20:00:00Z",
          "kind" => "entry",
          "direction" => "long",
          "price" => 105.0
        }
      ]
    }
  end

  test "pairs entries with exits, and keeps the trade still open at the end" do
    chart = SignalChart.shape(body(), @definition, "D")

    assert [first, open] = chart.trades
    assert %{entry_index: 1, exit_index: 3, reason: "rule"} = first
    assert_in_delta first.return, 0.02, 1.0e-9
    assert %{entry_index: 4, exit_index: nil, return: nil} = open

    assert [
             %{index: 1, kind: :buy},
             %{index: 3, kind: :sell},
             %{index: 4, kind: :buy}
           ] = chart.markers

    assert chart.spans == [{1, 3}, {4, 4}]
  end

  test "one strip per rule, in plain words, lit where it was true" do
    lanes = SignalChart.shape(body(), @definition, "D").lanes

    assert [
             %{ref: "r.long", role: :buy, label: "RSI(2) is below 20", runs: [{1, 2}, {4, 4}]},
             %{ref: "t.above", role: :buy, runs: [{0, 4}]},
             %{ref: "r.exit_long", role: :sell, runs: [{0, 0}, {3, 3}]}
           ] = lanes
  end

  test "a short trade opens with a sell and closes with a buy" do
    body = %{
      body()
      | "signals" => [
          %{
            "time" => "2026-10-02T20:00:00Z",
            "kind" => "entry",
            "direction" => "short",
            "price" => 100.0
          },
          %{
            "time" => "2026-10-03T20:00:00Z",
            "kind" => "exit",
            "direction" => "short",
            "price" => 98.0,
            "reason" => "stop_loss"
          }
        ]
    }

    chart = SignalChart.shape(body, @definition, "D")

    assert [%{kind: :sell}, %{kind: :buy}] = chart.markers
    assert_in_delta hd(chart.trades).return, 0.02, 1.0e-9
  end
end
