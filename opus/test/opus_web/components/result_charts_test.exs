defmodule OpusWeb.ResultChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OpusWeb.ResultCharts

  defp report(summary) do
    at = ~U[2024-01-02 00:00:00Z]

    %{
      points: [
        %{time: at, strategy: 0.0, hold: 0.0, matched: 0.0, drawdown: 0.0},
        %{
          time: DateTime.add(at, 365, :day),
          strategy: 0.2,
          hold: 1.0,
          matched: 0.1,
          drawdown: -0.02
        }
      ],
      summary:
        Map.merge(
          %{
            strategy_return: 0.2,
            strategy_max_drawdown: 0.04,
            strategy_annual_sharpe: 1.1,
            hold_return: 1.0,
            hold_max_drawdown: 0.35,
            hold_annual_sharpe: 0.8,
            matched_return: 0.1,
            matched_max_drawdown: 0.05,
            risk_scale: 0.12,
            correlation: 0.05,
            time_in_market: 0.05,
            num_trades: 300,
            risk_pct: 0.01,
            from: at,
            to: DateTime.add(at, 365, :day)
          },
          summary
        ),
      years: [
        %{year: 2024, strategy: 0.08, hold: 0.25, matched: 0.03},
        %{year: 2025, strategy: 0.11, hold: -0.3, matched: -0.04}
      ]
    }
  end

  test "compares the account with holding at the same risk, year by year" do
    html =
      render_component(&ResultCharts.vs_holding/1, report: report(%{}), instrument: "NAS100_USD")

    assert html =~ "The account made +20.0% over 300 trades"
    assert html =~ "Just holding NAS100_USD made +100%"
    assert html =~ "(12% of the money in it), holding made +10.0%"
    assert html =~ "the strategy did better (Sharpe 1.10 against 0.80)"
    assert html =~ "barely follow NAS100_USD"
    assert html =~ "Holding at the same risk +10%"
    assert html =~ "2025"
    assert html =~ "−30.0%"
  end

  test "says so when holding did as well for the risk, and when they move together" do
    html =
      render_component(&ResultCharts.vs_holding/1,
        report: report(%{matched_return: 0.3, correlation: 0.6}),
        instrument: "SPY"
      )

    assert html =~ "holding did as well or better"
    assert html =~ "part of what it makes is the market"
  end
end
