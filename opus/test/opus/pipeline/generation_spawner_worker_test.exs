defmodule Opus.Pipeline.GenerationSpawnerWorkerTest do
  use ExUnit.Case, async: true

  alias Opus.Pipeline.GenerationSpawnerWorker

  test "breeding_fitness_oos computes expected score with clamped retention" do
    wf_stats = %{"oos_sharpe" => 0.8, "sharpe_retention" => 2.2, "oos_num_trades" => 9}

    fitness = GenerationSpawnerWorker.breeding_fitness_oos(wf_stats)
    expected = 0.8 * 1.5 * :math.log(10.0)

    assert_in_delta(fitness, expected, 1.0e-12)
  end

  test "breeding_fitness_insample returns zero when expectancy non-positive" do
    bt_stats = %{"sharpe" => 1.5, "num_trades" => 42, "expectancy" => 0.0}

    assert GenerationSpawnerWorker.breeding_fitness_insample(bt_stats) == 0.0
  end

  test "breeding_fitness_insample computes score when expectancy positive" do
    bt_stats = %{"sharpe" => 0.6, "num_trades" => 24, "expectancy" => 0.01}

    fitness = GenerationSpawnerWorker.breeding_fitness_insample(bt_stats)
    expected = 0.6 * :math.log(25.0)

    assert_in_delta(fitness, expected, 1.0e-12)
  end

  test "select_parent prefers oos tier when walk-forward stats exist" do
    config_a = %{id: "a"}
    config_b = %{id: "b"}

    children = [
      %{
        config: config_a,
        bt_stats: %{"sharpe" => 9.0, "num_trades" => 100, "expectancy" => 1.0},
        wf_stats: nil
      },
      %{
        config: config_b,
        bt_stats: %{"sharpe" => 0.1, "num_trades" => 10, "expectancy" => 0.01},
        wf_stats: %{"oos_sharpe" => 0.5, "sharpe_retention" => 1.0, "oos_num_trades" => 10}
      }
    ]

    {parent, best_fitness} = GenerationSpawnerWorker.select_parent(children)

    assert parent == config_b
    assert best_fitness > 0.0
  end

  test "select_parent falls back to insample tier when no walk-forward stats exist" do
    config_a = %{id: "a"}
    config_b = %{id: "b"}

    children = [
      %{
        config: config_a,
        bt_stats: %{"sharpe" => 0.4, "num_trades" => 20, "expectancy" => 0.01},
        wf_stats: nil
      },
      %{
        config: config_b,
        bt_stats: %{"sharpe" => 0.2, "num_trades" => 20, "expectancy" => 0.01},
        wf_stats: nil
      }
    ]

    {parent, best_fitness} = GenerationSpawnerWorker.select_parent(children)

    assert parent == config_a
    assert best_fitness > 0.0
  end

  test "select_parent returns non-positive fitness when nothing has edge" do
    config_a = %{id: "a"}
    config_b = %{id: "b"}

    children = [
      %{
        config: config_a,
        bt_stats: %{"sharpe" => 1.0, "num_trades" => 50, "expectancy" => -0.01},
        wf_stats: nil
      },
      %{
        config: config_b,
        bt_stats: %{"sharpe" => 0.9, "num_trades" => 50, "expectancy" => 0.0},
        wf_stats: nil
      }
    ]

    {_parent, best_fitness} = GenerationSpawnerWorker.select_parent(children)

    assert best_fitness <= 0.0
  end
end
