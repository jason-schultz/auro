defmodule OpusWeb.PayoffChartTest do
  use ExUnit.Case, async: true

  alias OpusWeb.PayoffChart

  defp curve(label, days, f) do
    %{
      "label" => label,
      "days_to_expiry" => days,
      "points" => for(i <- 0..10, p = 90.0 + i * 2.0, do: %{"price" => p, "pnl" => f.(p)})
    }
  end

  test "lays out every curve, marks strike, breakeven and spot, and shades the expected move" do
    analysis = %{
      "strategy" => "long_call",
      "spot" => 100.0,
      "strike" => 102.0,
      "breakeven" => 104.0,
      "expected_move" => 5.0,
      "curves" => [
        curve("expiry", 0.0, fn p -> (max(p - 102.0, 0.0) - 2.0) * 100 end),
        curve("halfway", 15.0, fn p -> (p - 100.0) * 40 end),
        curve("today", 30.0, fn p -> (p - 100.0) * 30 end)
      ]
    }

    layout = PayoffChart.layout(analysis)

    assert Enum.map(layout.curves, & &1.label) == [
             "Today, 30 days left",
             "Halfway, 15 days left",
             "At expiry"
           ]

    assert Enum.all?(layout.curves, &(&1.points |> String.split(" ") |> length() == 11))

    assert Enum.map(layout.markers, & &1.text) == [
             "Strike 102.00",
             "Breakeven 104.00",
             "Now 100.00"
           ]

    assert layout.band.x1 < layout.band.x2
    assert layout.zero_y > 0 and layout.zero_y < layout.height
    assert layout.x_min == "90.00" and layout.x_max == "110.00"
  end

  test "markers outside the price grid are left out and no band without a move" do
    analysis = %{
      "strategy" => "long_put",
      "spot" => 100.0,
      "strike" => 50.0,
      "breakeven" => nil,
      "expected_move" => nil,
      "curves" => [curve("expiry", 0.0, fn _ -> -100.0 end)]
    }

    layout = PayoffChart.layout(analysis)
    assert Enum.map(layout.markers, & &1.text) == ["Now 100.00"]
    assert layout.band == nil
  end
end
