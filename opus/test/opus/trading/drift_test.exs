defmodule Opus.Trading.DriftTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.Drift

  @now ~U[2026-10-29 21:00:00Z]

  # A year of backtest: one trade a day, alternating +1.5% and −0.5%, so
  # the average trade is +0.5% (50 bp).
  defp backtest do
    %{
      trades: for(i <- 1..365, do: %{pnl: if(rem(i, 2) == 0, do: -0.005, else: 0.015)}),
      from: ~U[2024-01-01 00:00:00Z],
      to: ~U[2025-01-01 00:00:00Z]
    }
  end

  defp live(pnls), do: Enum.map(pnls, &%{pnl: &1})
  defp since(days), do: DateTime.add(@now, -days, :day)
  defp finding(result, check), do: Enum.find(result.findings, &(&1.check == check))

  test "under five live trades is too early for returns" do
    result = Drift.check(live([0.01, -0.01]), since(2), backtest(), nil, @now)
    assert finding(result, "returns").verdict == :too_early
  end

  test "live trades in line with the backtest read as fine" do
    pnls = [0.015, -0.005, 0.015, -0.005, 0.015, -0.005]
    result = Drift.check(live(pnls), since(6), backtest(), nil, @now)

    assert finding(result, "returns").verdict == :fine
    assert finding(result, "frequency").verdict == :fine
  end

  test "losses the backtest almost never has read as off" do
    result = Drift.check(live(List.duplicate(-0.005, 8)), since(8), backtest(), nil, @now)

    returns = finding(result, "returns")
    assert returns.verdict == :off
    assert returns.words =~ "isn't behaving like its backtest"
    assert result.verdict == :off
  end

  test "far fewer trades than the backtest's rate reads as off" do
    # About 30 expected in 30 days; none made.
    result = Drift.check([], since(30), backtest(), nil, @now)
    assert finding(result, "frequency").verdict == :off
    assert finding(result, "frequency").words =~ "trading far less"
  end

  test "fills eating over half the average trade read as watch" do
    fills = %{entries_measured: 6, mean_entry_slippage_bp: 20.0, mean_exit_slippage_bp: 10.0}
    pnls = [0.015, -0.005, 0.015, -0.005, 0.015, -0.005]
    result = Drift.check(live(pnls), since(6), backtest(), fills, @now)

    assert finding(result, "fills").verdict == :watch
    assert result.verdict == :watch
  end

  test "nothing to judge yet reads as too early" do
    result = Drift.check([], since(1), backtest(), nil, @now)
    assert result.verdict == :too_early
  end

  test "the same trades always read the same" do
    pnls = [0.01, -0.02, 0.005, -0.01, 0.0, -0.005]

    assert Drift.check(live(pnls), since(6), backtest(), nil, @now) ==
             Drift.check(live(pnls), since(6), backtest(), nil, @now)
  end

  test "poisson tails" do
    assert_in_delta Drift.poisson_at_most(0, 2.0), :math.exp(-2.0), 1.0e-12
    assert Drift.poisson_at_least(0, 5.0) == 1.0
    assert Drift.poisson_at_most(0, 30.0) < 1.0e-12
  end
end
