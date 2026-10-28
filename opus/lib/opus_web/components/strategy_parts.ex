defmodule OpusWeb.StrategyParts do
  @moduledoc """
  Pieces the strategy pages share: the lock badge (a strategy can't change
  while it trades), the evidence ladder (backtest, walk-forward, Monte
  Carlo, holdout, live) with every rule each stage was judged on next to
  its result, and a one-line test verdict for compact rows. Data from
  `Opus.Trading.StrategyResults`.
  """
  use Phoenix.Component

  import OpusWeb.CoreComponents, only: [icon: 1]
  import OpusWeb.Copy, only: [t: 1]
  import OpusWeb.Format

  attr :locked_by, :list, required: true, doc: "the assignment rows keeping it locked"

  def lock_badge(%{locked_by: []} = assigns) do
    ~H"""
    <span class="text-[13px] text-muted">
      <.t s="Not trading, so its rules can be changed" wsb="Benched, so you can mess with it" />
    </span>
    """
  end

  def lock_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 rounded-field border border-base-300 bg-base-200 px-2 py-0.5 text-[12px] font-medium">
      <.icon name="hero-lock-closed-mini" class="size-3.5" /> <.t s="Locked" wsb="Diamond-handed" />
    </span>
    <span class="text-[13px] text-muted">{locked_words(@locked_by)}</span>
    """
  end

  @doc "Why a strategy is locked, in a sentence: what's switched on and what's open."
  @spec locked_words([map()]) :: String.t()
  def locked_words(rows) do
    on = for r <- rows, r.enabled, do: r.instrument
    open = for r <- rows, r.open_trades > 0, do: r.instrument

    [
      on != [] && "switched on for #{Enum.join(on, ", ")}",
      open != [] && "open trade on #{Enum.join(open, ", ")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> Kernel.<>(". Its rules can't change while it's trading.")
    |> capitalize_first()
  end

  attr :results, :map, required: true

  def evidence(assigns) do
    ~H"""
    <dl class="grid grid-cols-1 gap-x-6 gap-y-2 text-[13px] sm:grid-cols-[8rem_minmax(0,1fr)]">
      <dt class="text-muted"><.t s="Backtest" wsb="Backtest (hopium)" /></dt>
      <dd class="m-0">
        <.stage stage={@results.backtest} line={backtest_line(@results.backtest)} />
      </dd>
      <dt class="text-muted">Walk-forward</dt>
      <dd class="m-0">
        <.stage stage={@results.walk_forward} line={walk_forward_line(@results.walk_forward)} />
      </dd>
      <dt class="text-muted">Monte Carlo</dt>
      <dd class="m-0">
        <.stage stage={@results.monte_carlo} line={monte_carlo_line(@results.monte_carlo)} />
      </dd>
      <dt class="text-muted">Holdout</dt>
      <dd class="m-0"><.stage stage={@results.holdout} /></dd>
      <%= if @results[:live] do %>
        <dt class="text-muted"><.t s="Live (forward)" wsb="Real life" /></dt>
        <dd class="m-0">{live_words(@results.live)}</dd>
      <% end %>
    </dl>
    """
  end

  attr :stage, :map, required: true
  attr :line, :string, default: nil

  defp stage(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span>
        <span :if={@stage.status == :passed} class="font-medium text-success">
          <.t s="Passed" wsb="Printed" />
        </span>
        <span :if={@stage.status == :failed} class="font-medium text-error">
          <.t s="Failed" wsb="GUH" />
        </span>
        <span :if={@stage.status in [:running, :pending]} class="font-medium text-warning">
          {if @stage.status == :running, do: "Running", else: "Waiting to run"}
        </span>
        <span :if={@stage.status == :not_run} class="text-muted">{@stage.reason}</span>
        <span :if={@line}>
          · {@line}<span :if={@stage.at} class="text-muted"> ({date(@stage.at)})</span>
        </span>
      </span>
      <ul :if={@stage.checks != []} class="m-0 flex list-none flex-col gap-0.5 p-0">
        <li :for={c <- @stage.checks} class="flex gap-1.5">
          <span aria-hidden="true" class={if c.passed, do: "text-success", else: "text-error"}>
            {if c.passed, do: "✓", else: "✗"}
          </span>
          <span>
            <span class="sr-only">{if c.passed, do: "Met:", else: "Missed:"}</span>
            {check_words(c)}
          </span>
        </li>
      </ul>
      <span
        :if={@stage.status == :failed && @stage.reason && @stage.checks == []}
        class="text-muted"
      >
        {@stage.reason}
      </span>
    </div>
    """
  end

  @doc "Test runs on instruments, one collapsed row each with its verdict; open for the full results."
  attr :runs, :list, required: true, doc: "StrategyResults.for_recipe/1"

  def runs_list(assigns) do
    ~H"""
    <details :for={run <- @runs} class="rounded-field bg-base-100 px-4 py-2.5">
      <summary class="flex min-h-9 cursor-pointer flex-wrap items-baseline gap-x-3">
        <span class="font-medium">{run.instrument}</span>
        <.test_badge results={run.stages} />
      </summary>
      <div class="pt-2"><.evidence results={run.stages} /></div>
    </details>
    """
  end

  @doc "A short verdict for a row of tests: passed, failed (and where), testing, or not tested."
  attr :results, :map, required: true

  def test_badge(assigns) do
    assigns = assign(assigns, verdict: verdict(assigns.results))

    ~H"""
    <span class={["inline-flex items-center gap-1 text-[13px]", @verdict.class]}>
      <span aria-hidden="true">{@verdict.mark}</span> {@verdict.words}
    </span>
    """
  end

  @stage_names [
    backtest: "backtest",
    walk_forward: "walk-forward",
    monte_carlo: "Monte Carlo",
    holdout: "holdout"
  ]

  defp verdict(results) do
    stages = Enum.map(@stage_names, fn {key, name} -> {name, results[key]} end)

    cond do
      failed = Enum.find(stages, fn {_name, s} -> s.status == :failed end) ->
        %{mark: "✗", words: "failed the #{elem(failed, 0)}", class: "text-error"}

      Enum.any?(stages, fn {_name, s} -> s.status in [:pending, :running] end) ->
        %{mark: "…", words: "testing", class: "text-warning"}

      results.backtest.status == :not_run ->
        %{mark: "–", words: "not tested", class: "text-muted"}

      true ->
        passed = Enum.count(stages, fn {_name, s} -> s.status == :passed end)
        %{mark: "✓", words: "passed #{passed} of 4 tests", class: "text-success"}
    end
  end

  @metrics %{
    "num_trades" => {"Trades", :count},
    "t_stat" => {"Luck test (t)", :number},
    "max_drawdown" => {"Worst drop", :share},
    "total_return" => {"Return", :share},
    "expectancy" => {"Average trade", :share},
    "sharpe" => {"Sharpe per trade", :number},
    "oos_num_trades" => {"Trades on unseen data", :count},
    "oos_return" => {"Return on unseen data", :share},
    "oos_t_stat" => {"Luck test on unseen data (t)", :number},
    "oos_sharpe" => {"Sharpe per trade on unseen data", :number},
    "sharpe_retention" => {"Quality kept on unseen data", :share},
    "profitable_pct" => {"Redrawn histories that made money", :share},
    "p95_drawdown" => {"Bad-run drop (1 in 20)", :share},
    "median_sharpe" => {"Median Sharpe per trade", :number}
  }

  @operators %{"gte" => "at least", "gt" => "more than", "lte" => "at most", "lt" => "less than"}

  # "Trades 129 (needs at least 30)"
  defp check_words(%{metric: metric, operator: op, required: required, actual: actual}) do
    {label, kind} = Map.get(@metrics, metric, {metric, :number})
    "#{label} #{value(actual, kind)} (needs #{@operators[op] || op} #{value(required, kind)})"
  end

  defp value(nil, _kind), do: "missing"
  defp value(v, :count), do: num(round(v))
  defp value(v, :share), do: pct(v)
  defp value(v, :number), do: num(v)

  defp backtest_line(%{stats: %{"total_return" => r, "num_trades" => n} = s}),
    do:
      "#{signed_pct(r)} over #{n} trades, #{pct(s["win_rate"], 0)} won, worst drop #{pct(s["max_drawdown"])}"

  defp backtest_line(_), do: nil

  defp walk_forward_line(%{stats: %{"is_return" => is, "oos_return" => oos} = s}),
    do:
      "fitted on older data: #{signed_pct(is)} over #{s["is_num_trades"]} trades; " <>
        "then on later data it hadn't seen: #{signed_pct(oos)} over #{s["oos_num_trades"]} trades"

  defp walk_forward_line(_), do: nil

  defp monte_carlo_line(%{stats: %{"p95_drawdown" => dd, "profitable_pct" => made} = s}),
    do:
      "its trades redrawn at random #{num(s["num_sims"], 0)} times: #{pct(made)} of those " <>
        "histories made money, and a bad run (1 in 20) falls #{pct(dd)}"

  defp monte_carlo_line(_), do: nil

  defp live_words(%{trades: 0}), do: "No closed trades yet."

  defp live_words(%{trades: n, wins: wins, pnl: pnl, since: since}) do
    "#{n} closed #{if n == 1, do: "trade", else: "trades"} since #{date(since)}, " <>
      "#{wins} won, #{signed_money(pnl)} on the practice account"
  end

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
