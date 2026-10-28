defmodule Opus.Trading.StrategyResultsTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.StrategyResults

  test "the checks the engine recorded come back as they are" do
    stats = %{
      "checks" => [
        %{
          "metric" => "t_stat",
          "operator" => "gte",
          "required" => 2.0,
          "actual" => 2.4,
          "passed" => true
        }
      ]
    }

    assert [%{metric: "t_stat", operator: "gte", required: 2.0, actual: 2.4, passed: true}] =
             StrategyResults.checks(stats, nil)
  end

  test "an older run's failed rules are read back out of its failure text" do
    reason =
      "sharpe_retention: -0.6566 is below minimum 0.3000; oos_return: -0.0520 must be greater than 0.0000"

    assert [
             %{
               metric: "sharpe_retention",
               operator: "gte",
               actual: -0.6566,
               required: 0.3,
               passed: false
             },
             %{
               metric: "oos_return",
               operator: "gt",
               actual: -0.052,
               required: +0.0,
               passed: false
             }
           ] = StrategyResults.checks(%{}, reason)

    assert StrategyResults.checks(%{}, "no candle data for SHOP M5") == []
  end
end
