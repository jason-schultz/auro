defmodule OpusWeb.Components.ValueLineTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OpusWeb.Components.ValueLine

  test "a line with its low and high, a hover per day and a table view" do
    points = [
      %{on: ~D[2026-10-28], value: 1000.0},
      %{on: ~D[2026-10-29], value: 900.0},
      %{on: ~D[2026-10-30], value: 1100.0}
    ]

    html = render_component(&ValueLine.value_line/1, id: "nw", points: points, label: "Net worth")

    assert html =~ "<polyline"
    assert html =~ ~s|aria-label="Net worth, Oct 28 to Oct 30"|
    assert html =~ "$1,100.00"
    assert html =~ "$900.00"
    assert html =~ "<title>Oct 29: $900.00</title>"
    assert html =~ "(+$100.00 over the line)"
    assert html =~ "As a table"
  end

  test "fewer than two points says why there's no line" do
    html =
      render_component(&ValueLine.value_line/1,
        id: "nw",
        points: [%{on: ~D[2026-10-30], value: 1.0}],
        label: "Net worth",
        empty: "Starts at the next close."
      )

    assert html =~ "Starts at the next close."
    refute html =~ "<svg"
  end
end
