defmodule OpusWeb.CandleChartTest do
  use ExUnit.Case, async: true

  alias OpusWeb.CandleChart

  @t0 ~U[2026-10-22 14:30:00Z]

  defp candle(i, open, close) do
    %{
      time: DateTime.add(@t0, i * 300, :second),
      open: open,
      high: max(open, close) + 2,
      low: min(open, close) - 2,
      close: close
    }
  end

  test "lays out every shown candle, colours by direction, and keeps lines in range" do
    candles = [candle(0, 100.0, 104.0), candle(1, 104.0, 101.0), candle(2, 101.0, 103.0)]

    lines = [
      %{price: 102.0, label: "Entry", kind: :entry},
      %{price: 150.0, label: "Stop", kind: :stop}
    ]

    layout = CandleChart.layout(candles, lines, nil, nil)

    assert length(layout.drawn) == 3
    assert [up, down, _] = layout.drawn
    assert up.color =~ "success" and down.color =~ "error"
    assert Enum.all?(layout.drawn, &(&1.high <= &1.top and &1.top + &1.height <= &1.low))

    assert [%{text: "102.00"}] = layout.drawn_lines
    assert [%{text: text, y: 0}] = layout.edge_notes
    assert text =~ "Stop 150.00 is 45.6% above, off this chart"
    assert layout.overlay == nil
    assert layout.first_time == "Oct 22 14:30" and layout.last_time == "Oct 22 14:40"
  end

  test "shows only the trailing bars but averages over the hidden ones" do
    candles = for i <- 0..5, do: candle(i, 100.0 + i, 101.0 + i)

    layout = CandleChart.layout(candles, [], 3, 3)

    assert length(layout.drawn) == 3
    # Three shown bars, each with a full three-bar window behind it.
    assert layout.overlay |> String.split(" ") |> length() == 3
  end
end
