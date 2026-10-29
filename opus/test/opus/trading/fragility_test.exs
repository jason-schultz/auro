defmodule Opus.Trading.FragilityTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.Fragility

  @definition %{
    "components" => %{
      "r" => %{
        "type" => "RsiReversion",
        "params" => %{"rsi_period" => 2, "oversold" => 20, "overbought" => 80}
      },
      "t" => %{"type" => "MaFilter", "params" => %{"period" => 100, "ma_type" => "sma"}}
    }
  }

  test "the settings it can vary are each block's numbers, in plain words" do
    assert [
             %{id: "r.rsi_period", label: "RSI · Bars to look at", kind: :int, value: 2},
             %{id: "r.oversold", label: "RSI · Oversold below", kind: :float},
             %{id: "r.overbought"},
             %{id: "t.period", label: "Moving average · Bars", kind: :int, value: 100}
           ] = Fragility.axes(@definition)
  end

  test "nearby values run from half to one and a half times, bar counts whole" do
    [period, oversold | _] = Fragility.axes(@definition)

    assert Fragility.values(oversold) == [10.0, 15.0, 20.0, 25.0, 30.0]
    assert Fragility.values(period) == [1, 2, 3]
    assert Fragility.values(%{kind: :int, value: 100}) == [50, 75, 100, 125, 150]
  end

  defp cell(x, y, passed, ret \\ 0.1),
    do: %{
      "x" => x,
      "y" => y,
      "total_return" => ret,
      "num_trades" => 50,
      "t_stat" => 2.5,
      "passed" => passed
    }

  test "a neighbourhood that passes is sturdy, and the current cell is marked" do
    x = %{value: 20, kind: :float}
    y = %{value: 100, kind: :int}

    cells =
      for yv <- [50, 100, 150], xv <- [10.0, 20.0, 30.0], do: cell(xv, yv, xv != 30.0)

    grid = Fragility.shape(cells, x, y)

    assert grid.verdict.tone == :sturdy
    assert grid.verdict.words =~ "6 of 9 nearby settings"
    assert [%{y: 150}, %{y: 100}, %{y: 50}] = grid.rows
    assert grid.xs == [10.0, 20.0, 30.0]
    assert Enum.count(Enum.flat_map(grid.rows, & &1.cells), & &1.current) == 1
  end

  test "a lone passing cell is fragile; failing at the current settings says so" do
    x = %{value: 20, kind: :float}

    lone =
      Fragility.shape(
        [
          cell(10.0, nil, false),
          cell(15.0, nil, false),
          cell(20.0, nil, true),
          cell(25.0, nil, false),
          cell(30.0, nil, false, -0.1)
        ],
        x,
        nil
      )

    assert lone.verdict.tone == :fragile

    weak =
      Fragility.shape(
        [cell(10.0, nil, true), cell(20.0, nil, false), cell(30.0, nil, true)],
        x,
        nil
      )

    assert weak.verdict.tone == :weak
    assert weak.verdict.words =~ "These exact settings don't pass"
  end
end
