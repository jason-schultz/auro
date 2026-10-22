defmodule Opus.Trading.ExecutionQualityTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.ExecutionQuality, as: EQ

  defp trade(attrs) do
    Map.merge(
      %{
        live_strategy_id: "s1",
        direction: "long",
        entry_price: nil,
        exit_price: nil,
        expected_entry_price: nil,
        entry_spread: nil,
        expected_exit_price: nil,
        exit_spread: nil
      },
      attrs
    )
  end

  test "long entry filled above the expected ask is positive slippage" do
    t = trade(%{entry_price: 10_010.0, expected_entry_price: 10_000.0})
    assert_in_delta EQ.entry_slippage_bp(t), 10.0, 1.0e-9
  end

  test "short entry filled below the expected bid is positive slippage" do
    t = trade(%{direction: "short", entry_price: 9_990.0, expected_entry_price: 10_000.0})
    assert_in_delta EQ.entry_slippage_bp(t), 10.0, 1.0e-9
  end

  test "a better-than-expected fill is negative slippage" do
    t = trade(%{entry_price: 9_995.0, expected_entry_price: 10_000.0})
    assert_in_delta EQ.entry_slippage_bp(t), -5.0, 1.0e-9
  end

  test "exit slippage is positive when a long sells below the expected bid" do
    t = trade(%{exit_price: 9_980.0, expected_exit_price: 10_000.0})
    assert_in_delta EQ.exit_slippage_bp(t), 20.0, 1.0e-9

    short = trade(%{direction: "short", exit_price: 10_020.0, expected_exit_price: 10_000.0})
    assert_in_delta EQ.exit_slippage_bp(short), 20.0, 1.0e-9
  end

  test "stop-loss exits without an expected price are not measured" do
    assert EQ.exit_slippage_bp(trade(%{exit_price: 9_900.0})) == nil
    assert EQ.entry_slippage_bp(trade(%{entry_price: 1.0})) == nil
  end

  test "spread is expressed in basis points of the expected entry" do
    t = trade(%{entry_spread: 2.0, expected_entry_price: 20_000.0})
    assert_in_delta EQ.entry_spread_bp(t), 1.0, 1.0e-9
  end

  test "summarize groups by strategy and counts what it measured" do
    trades = [
      trade(%{
        entry_price: 10_010.0,
        expected_entry_price: 10_000.0,
        entry_spread: 1.0,
        exit_price: 9_990.0,
        expected_exit_price: 10_000.0
      }),
      trade(%{
        entry_price: 10_030.0,
        expected_entry_price: 10_000.0,
        entry_spread: 3.0,
        exit_price: 9_900.0
      }),
      trade(%{
        live_strategy_id: "s2",
        direction: "short",
        entry_price: 9_995.0,
        expected_entry_price: 10_000.0
      })
    ]

    assert [s1, s2] = EQ.summarize(trades)

    assert s1.live_strategy_id == "s1"
    assert s1.trades == 2
    assert s1.entries_measured == 2
    assert s1.exits_measured == 1
    assert s1.mean_entry_slippage_bp == 20.0
    assert s1.median_entry_slippage_bp == 20.0
    assert s1.mean_exit_slippage_bp == 10.0
    assert s1.mean_spread_bp == 2.0
    assert s1.mean_round_trip_excess_bp == 30.0

    assert s2.trades == 1
    assert s2.mean_entry_slippage_bp == 5.0
    assert s2.exits_measured == 0
    assert s2.mean_exit_slippage_bp == nil
    assert s2.mean_round_trip_excess_bp == nil
  end
end
