defmodule OpusWeb.StrategyPartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OpusWeb.StrategyParts

  defp walk_forward(sure, checks) do
    %{
      status: :passed,
      stats: %{"deflated_sharpe" => sure, "n_trials" => 10},
      checks: checks,
      reason: nil,
      at: nil
    }
  end

  defp bar(passed, required \\ 0.95),
    do: [
      %{
        metric: "deflated_sharpe",
        operator: "gte",
        required: required,
        actual: 0.87,
        passed: passed
      }
    ]

  test "the luck check says how sure it is, what it needs and which side of the bar it's on" do
    html =
      render_component(&StrategyParts.luck_check/1, walk_forward: walk_forward(0.87, bar(false)))

    assert html =~ "Luck check:"
    assert html =~ "87% sure this isn&#39;t luck, after trying it on 10 markets"
    assert html =~ "needs 95%"
    assert html =~ "below the bar"
    refute html =~ "clears the bar"

    html =
      render_component(&StrategyParts.luck_check/1, walk_forward: walk_forward(0.97, bar(true)))

    assert html =~ "clears the bar"
  end

  test "between the pipeline's bar and 95% it passes with a flag to watch it" do
    html =
      render_component(&StrategyParts.luck_check/1,
        walk_forward: walk_forward(0.87, bar(true, 0.80))
      )

    assert html =~ "needs 80%"
    assert html =~ "passes, but under 95%: watch it"
    refute html =~ "clears the bar"
    refute html =~ "below the bar"
  end

  test "settings tried on one market are named and counted as fewer tries" do
    stage =
      put_in(
        walk_forward(0.9, bar(true, 0.80)).stats,
        %{"deflated_sharpe" => 0.9, "n_trials" => 7, "n_markets" => 4, "n_settings" => 9}
      )

    html = render_component(&StrategyParts.luck_check/1, walk_forward: stage)

    assert html =~
             "90% sure this isn&#39;t luck, after trying it on 4 markets"

    assert html =~ "with 9 different settings, counted as about 7 tries"
    assert html =~ "counts as the square root of its settings"

    # One setting per market: nothing extra to explain.
    one_each = put_in(stage.stats, %{stage.stats | "n_settings" => 4, "n_trials" => 4})
    html = render_component(&StrategyParts.luck_check/1, walk_forward: one_each)

    assert html =~ "after trying it on 4 markets"
    refute html =~ "different settings"
    refute html =~ "square root"
  end

  test "nothing shows until a walk-forward has recorded a deflated Sharpe" do
    stage = %{status: :passed, stats: %{"oos_sharpe" => 0.1}, checks: [], reason: nil, at: nil}

    assert render_component(&StrategyParts.luck_check/1, walk_forward: stage) |> String.trim() ==
             ""

    not_run = %{status: :not_run, stats: nil, checks: [], reason: "Not run.", at: nil}

    assert render_component(&StrategyParts.luck_check/1, walk_forward: not_run) |> String.trim() ==
             ""
  end

  defp not_run, do: %{status: :not_run, stats: nil, checks: [], reason: "Not run.", at: nil}

  defp results(backtest),
    do: %{
      backtest: backtest,
      walk_forward: not_run(),
      monte_carlo: not_run(),
      parameter_stability: not_run(),
      holdout: not_run()
    }

  test "the backtest headline is the compounded account; the gated sum is named as a sum" do
    backtest = %{
      status: :failed,
      stats: %{
        "account_return" => -0.042,
        "account_max_drawdown" => 0.081,
        "account_risk_pct" => 0.01,
        "total_return" => -1.35,
        "max_drawdown" => 1.5,
        "num_trades" => 120,
        "win_rate" => 0.41
      },
      checks: [
        %{metric: "max_drawdown", operator: "lte", required: 0.25, actual: 1.5, passed: false}
      ],
      reason: nil,
      at: nil
    }

    html = render_component(&StrategyParts.evidence/1, results: results(backtest))

    assert html =~
             "Account −4.2% at 1.0% risk a trade, compounded; its worst drop 8.1%. " <>
               "120 trades, 41% won. Trades added up: −135.0%, worst drop 150.0%"

    assert html =~ "Worst drop, trades added up 150.0% (needs at most 25.0%)"

    # Saved since open trades are valued at every close, the drop says so.
    stats = Map.put(backtest.stats, "drawdown_valued", "every_close")

    html =
      render_component(&StrategyParts.evidence/1, results: results(%{backtest | stats: stats}))

    assert html =~
             "Worst drop, trades added up, valued at every close 150.0% (needs at most 25.0%)"
  end

  test "a backtest saved before the account figures says its numbers are added up" do
    backtest = %{
      status: :passed,
      stats: %{
        "total_return" => 0.3,
        "max_drawdown" => 0.1,
        "num_trades" => 40,
        "win_rate" => 0.5
      },
      checks: [],
      reason: nil,
      at: nil
    }

    html = render_component(&StrategyParts.evidence/1, results: results(backtest))
    assert html =~ "Trades added up: +30.0% over 40 trades, 50% won, worst drop 10.0%"
  end
end
