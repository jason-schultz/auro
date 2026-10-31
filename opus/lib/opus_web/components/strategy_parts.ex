defmodule OpusWeb.StrategyParts do
  @moduledoc """
  Pieces the strategy pages share: the lock badge (a strategy can't change
  while it trades), the evidence ladder (backtest, walk-forward, Monte
  Carlo, nearby settings, holdout, live) with every rule each stage was judged on next to
  its result, and a one-line test verdict for compact rows. Data from
  `Opus.Trading.StrategyResults`.
  """
  use Phoenix.Component

  import OpusWeb.CoreComponents, only: [icon: 1]
  import OpusWeb.Copy, only: [t: 1, copy: 1, copy: 2, copy_n: 4, pcopy: 2]
  import OpusWeb.Format

  alias Opus.Pipeline.Stuck

  attr :locked_by, :list, required: true, doc: "the assignment rows keeping it locked"

  def lock_badge(%{locked_by: []} = assigns) do
    ~H"""
    <span class="text-[13px] text-muted">
      <.t {copy("Not trading, so its rules can be changed")} />
    </span>
    """
  end

  def lock_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 rounded-field border border-base-300 bg-base-200 px-2 py-0.5 text-[12px] font-medium">
      <.icon name="hero-lock-closed-mini" class="size-3.5" /> <.t {copy("Locked")} />
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

  @doc "A form field: its label above the control, an optional line of help under it."
  attr :label, :string, required: true
  attr :help, :string, default: nil
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <label class="flex flex-col gap-1 text-[13px] text-muted">
      {@label}
      {render_slot(@inner_block)}
      <span :if={@help} class="text-[12px] leading-snug">{@help}</span>
    </label>
    """
  end

  @doc "One figure in a `<dl>`: a small muted label over the value."
  attr :label, :map, required: true, doc: "copy/1"
  attr :value, :string, required: true
  attr :large, :boolean, default: false
  attr :class, :any, default: nil, doc: "extra classes on the value, e.g. its tone"

  def stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <dt class="text-xs text-muted"><.t {@label} /></dt>
      <dd class={["m-0 font-semibold", if(@large, do: "text-[22px]", else: "text-[18px]"), @class]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :results, :map, required: true

  def evidence(assigns) do
    ~H"""
    <dl class="grid grid-cols-1 gap-x-6 gap-y-2 text-[13px] sm:grid-cols-[8rem_minmax(0,1fr)]">
      <dt class="text-muted"><.t {copy("Backtest")} /></dt>
      <dd class="m-0">
        <.stage stage={@results.backtest} line={backtest_line(@results.backtest)} />
        <span :if={costs_words(@results.backtest)} class="block text-muted">
          {costs_words(@results.backtest)}
        </span>
        <span :if={hold_words(@results.backtest)} class="block">
          {hold_words(@results.backtest)}
        </span>
      </dd>
      <dt class="text-muted">Walk-forward</dt>
      <dd class="m-0">
        <.stage stage={@results.walk_forward} line={walk_forward_line(@results.walk_forward)} />
      </dd>
      <dt class="text-muted">Monte Carlo</dt>
      <dd class="m-0">
        <.stage stage={@results.monte_carlo} line={monte_carlo_line(@results.monte_carlo)} />
      </dd>
      <dt class="text-muted"><.t {copy("Nearby settings")} /></dt>
      <dd class="m-0">
        <.stage
          stage={@results.parameter_stability}
          line={parameter_stability_line(@results.parameter_stability)}
        />
      </dd>
      <dt class="text-muted">Holdout</dt>
      <dd class="m-0"><.stage stage={@results.holdout} /></dd>
      <%= if @results[:live] do %>
        <dt class="text-muted"><.t {copy("Live (forward)")} /></dt>
        <dd class="m-0">{live_words(@results.live)}</dd>
      <% end %>
    </dl>
    <p class="m-0 text-[12px] text-muted">
      <.t {copy(
        "Account figures size each trade the way it would trade live, at the risk shown, and compound them. \"Trades added up\" is each trade's price move summed as if every trade used the whole account: the pass marks were set on it, so it stays, named for what it is. The Together page shows several strategies on one account."
      )} />
    </p>
    """
  end

  attr :stage, :map, required: true
  attr :line, :any, default: nil, doc: "a string, or both voices (`copy/2`)"

  defp stage(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span>
        <span :if={@stage.status == :passed} class="font-medium text-success">
          <.t {copy("Passed")} />
        </span>
        <span :if={@stage.status == :failed} class="font-medium text-error">
          <.t {pcopy("test result", "Failed")} />
        </span>
        <span :if={@stage.status == :old_pass} class="font-medium text-warning">
          <.t {copy("Passed older rules")} />
        </span>
        <span :if={@stage.status == :old_fail} class="font-medium text-warning">
          <.t {copy("Failed older rules")} />
        </span>
        <span :if={@stage.status in [:running, :pending]} class="font-medium text-warning">
          {if @stage.status == :running, do: "Running", else: "Waiting to run"}
        </span>
        <span :if={@stage.status == :stuck} class="font-medium text-warning">
          <.t {pcopy("test stage", "Stopped")} />
        </span>
        <span :if={@stage.status in [:not_run, :old_pass, :old_fail, :stuck]} class="text-muted">
          <span :if={@stage.status in [:old_pass, :old_fail]}>·</span> {@stage.reason}
        </span>
        <span :if={@line}>
          ·
          <.t :if={is_map(@line)} {@line} /><span :if={!is_map(@line)}>{@line}</span><span
            :if={@stage.at}
            class="text-muted"
          > ({date(@stage.at)})</span>
        </span>
      </span>
      <ul :if={@stage.checks != []} class="m-0 flex list-none flex-col gap-0.5 p-0">
        <li :for={c <- @stage.checks} class="flex gap-1.5">
          <span aria-hidden="true" class={if c.passed, do: "text-success", else: "text-error"}>
            {if c.passed, do: "✓", else: "✗"}
          </span>
          <span>
            <span class="sr-only">{if c.passed, do: "Met:", else: "Missed:"}</span>
            {check_words(c, @stage.stats)}
          </span>
        </li>
      </ul>
      <span
        :if={@stage.status == :failed && @stage.reason && @stage.checks == []}
        class="text-muted"
      >
        {@stage.reason}
      </span>
      <.resume_button :if={@stage.status == :stuck} config_id={@stage.config_id} stage={@stage.stage} />
    </div>
    """
  end

  @doc """
  "Resume from <stage>" for a stuck stage (`Opus.Pipeline.Stuck`): the page
  handles `"resume_stage"` with `resume/1`. The holdout asks first, and
  only a confirmed click sends `holdout=confirmed`: running it takes the
  one-time look at the data kept aside.
  """
  attr :config_id, :string, required: true
  attr :stage, :atom, required: true

  attr :class, :any,
    default:
      "min-h-11 self-start rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary"

  def resume_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="resume_stage"
      phx-value-config={@config_id}
      phx-value-stage={@stage}
      phx-value-holdout={if @stage == :holdout, do: "confirmed"}
      data-confirm={if @stage == :holdout, do: holdout_confirm()}
      class={@class}
    >
      <.t {copy("Resume from %{stage}", stage: stage_name(@stage))} />
    </button>
    """
  end

  @doc """
  Resume a stuck stage for a page's `"resume_stage"` event
  (`resume_button/1`): `{flash kind, words}`.
  """
  @spec resume(map()) :: {:info | :error, String.t()}
  def resume(%{"config" => config_id, "stage" => stage} = params) do
    opts = if params["holdout"] == "confirmed", do: [holdout: :confirmed], else: []
    name = stage_words(stage)

    case Stuck.resume(config_id, stage, opts) do
      {:ok, _job} ->
        {:info, "Resumed from the #{name}. It shows as running or waiting until it's done."}

      {:error, :holdout_needs_confirm} ->
        {:error,
         "The holdout is the one-time look at the data kept aside: resume it from its button and confirm."}

      {:error, :archived} ->
        {:error,
         "This run is in the archive (tested before the block builder): re-test it instead."}

      {:error, :not_stuck} ->
        {:error, "Nothing to resume: the #{name} is already running, waiting or finished."}

      {:error, _reason} ->
        {:error, "Couldn't resume the #{name}."}
    end
  end

  # A luck check this sure is a clean pass; between the pipeline's bar and
  # this, the strategy passes with a flag to watch it.
  @clean_pass 0.95

  @doc """
  The luck check for a live strategy: its latest walk-forward's deflated
  Sharpe in words (how sure it isn't luck from trying the idea on many
  markets and settings) against the bar it needs, and how the tries were
  counted when some market had more than one setting. Nothing until a
  walk-forward has recorded one.
  """
  attr :walk_forward, :map, required: true, doc: "the walk-forward stage (`StrategyResults`)"

  def luck_check(assigns) do
    assigns = assign(assigns, luck: luck(assigns.walk_forward), clean_pass: @clean_pass)

    ~H"""
    <p :if={@luck} class="m-0 text-[13px]">
      <span class="font-medium"><.t {copy("Luck check:")} /></span>
      <.t {copy_n(
        "%{sure} sure this isn't luck, after trying it on %{count} market",
        "%{sure} sure this isn't luck, after trying it on %{count} markets",
        @luck.markets,
        sure: pct(@luck.sure, 0)
      )} />
      <.t
        :if={@luck.settings}
        {copy_n(
          "with %{settings} different settings, counted as about %{count} try",
          "with %{settings} different settings, counted as about %{count} tries",
          @luck.tries,
          settings: @luck.settings
        )}
      />
      <span :if={@luck.needed}>
        (<.t {copy("needs %{needed}", needed: pct(@luck.needed, 0))} />)
      </span>
      <span :if={@luck.needed && @luck.met && @luck.clean} class="font-medium">
        · <.t {copy("clears the bar")} />
      </span>
      <span :if={@luck.needed && @luck.met && !@luck.clean} class="font-medium text-warning">
        · <.t {copy("passes, but under %{clean}: watch it", clean: pct(@clean_pass, 0))} />
      </span>
      <span :if={@luck.needed && !@luck.met} class="font-medium text-warning">
        · <.t {copy("below the bar")} />
      </span>
      <span :if={@luck.settings} class="block text-[12px] text-muted">
        <.t {copy(
          "Settings tried on one market mostly repeat each other, so each market counts as the square root of its settings: 4 settings count as 2 tries, 9 as 3."
        )} />
      </span>
    </p>
    """
  end

  defp luck(%{stats: %{"deflated_sharpe" => sure} = stats} = stage) when is_number(sure) do
    needed =
      Enum.find_value(stage[:checks] || [], fn c ->
        if c.metric == "deflated_sharpe", do: c.required
      end)

    tries = stats["n_trials"] || 1
    markets = stats["n_markets"] || tries
    settings = stats["n_settings"]

    %{
      sure: sure,
      tries: tries,
      markets: markets,
      # Only worth saying when some market was tried with more than one
      # setting (older walk-forwards counted markets only).
      settings: if(is_integer(settings) and settings > markets, do: settings),
      needed: needed,
      met: is_number(needed) and sure >= needed,
      clean: sure >= @clean_pass
    }
  end

  defp luck(_stage), do: nil

  @doc "Test runs on instruments, one collapsed row each with its verdict; open for the full results."
  attr :runs, :list, required: true, doc: "StrategyResults.for_recipe/1"

  def runs_list(assigns) do
    ~H"""
    <details :for={run <- @runs} class="rounded-field bg-base-100 px-4 py-2.5">
      <summary class="flex min-h-9 cursor-pointer flex-wrap items-baseline gap-x-3">
        <span class="font-medium">{run.instrument}</span>
        <.test_badge results={run.stages} />
        <.archive_mark :if={run.archived} />
      </summary>
      <div class="pt-2"><.evidence results={run.stages} /></div>
    </details>
    """
  end

  @doc """
  The switch for test runs from before the block builder (`archived`):
  hidden by default, counted on the button. The page handles `"archive"`.
  """
  attr :count, :integer, required: true, doc: "archived runs on the page"
  attr :shown, :boolean, required: true

  def archive_toggle(assigns) do
    ~H"""
    <button
      :if={@count > 0}
      type="button"
      phx-click="archive"
      aria-pressed={to_string(@shown)}
      class="self-start text-[13px] font-medium text-primary hover:brightness-110"
    >
      <.t
        :if={!@shown}
        {copy("Show the archive (%{count}): tried before the block builder", count: @count)}
      />
      <.t :if={@shown} {copy("Hide the archive")} />
    </button>
    """
  end

  @doc "Marks a test run from the archive."
  def archive_mark(assigns) do
    ~H"""
    <span class="text-[12px] text-muted"><.t {pcopy("test run", "archive")} /></span>
    """
  end

  @doc "The runs a page shows: archived ones only when the archive is shown."
  @spec visible_runs([map()], boolean()) :: [map()]
  def visible_runs(runs, true), do: runs
  def visible_runs(runs, false), do: Enum.reject(runs, & &1.archived)

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
    parameter_stability: "nearby-settings test",
    holdout: "holdout"
  ]

  @doc "A stage's name as a verdict says it: `:monte_carlo` is \"Monte Carlo\"."
  @spec stage_name(atom()) :: String.t()
  def stage_name(stage), do: Keyword.fetch!(@stage_names, stage)

  # A stage's name from its database string, as an event sends it.
  defp stage_words(stage) do
    Enum.find_value(@stage_names, "stage", fn {key, name} ->
      Atom.to_string(key) == stage && name
    end)
  end

  defp holdout_confirm,
    do:
      "Run the holdout now? It's the one-time look at the data kept aside: whatever it shows " <>
        "is final, and this strategy can't be judged on that data again."

  @doc """
  Why a stage failed, short: the first rule it missed in words, or its
  failure text when it recorded no rules.
  """
  @spec missed_words(map()) :: String.t() | nil
  def missed_words(%{checks: checks, stats: stats, reason: reason}) do
    case Enum.find(checks, &(!&1.passed)) do
      nil -> reason
      check -> check_words(check, stats)
    end
  end

  defp verdict(results) do
    stages = Enum.map(@stage_names, fn {key, name} -> {name, results[key]} end)

    cond do
      failed = Enum.find(stages, fn {_name, s} -> s.status == :failed end) ->
        %{mark: "✗", words: "failed the #{elem(failed, 0)}", class: "text-error"}

      stuck = Enum.find(stages, fn {_name, s} -> s.status == :stuck end) ->
        %{mark: "!", words: "stopped at the #{elem(stuck, 0)}; resume it", class: "text-warning"}

      Enum.any?(stages, fn {_name, s} -> s.status in [:pending, :running] end) ->
        %{mark: "…", words: "testing", class: "text-warning"}

      results.backtest.status == :not_run ->
        %{mark: "–", words: "not tested", class: "text-muted"}

      old_fail = Enum.find(stages, fn {_name, s} -> s.status == :old_fail end) ->
        %{
          mark: "~",
          words: "failed the #{elem(old_fail, 0)} by older rules; re-test it",
          class: "text-warning"
        }

      Enum.any?(stages, fn {_name, s} -> s.status == :old_pass end) ->
        %{mark: "~", words: "passed older rules; re-test it", class: "text-warning"}

      true ->
        passed = Enum.count(stages, fn {_name, s} -> s.status == :passed end)

        %{
          mark: "✓",
          words: "passed #{passed} of #{length(stages)} tests",
          class: "text-success"
        }
    end
  end

  @metrics %{
    "num_trades" => {"Trades", :count},
    "num_months" => {"Months of results", :count},
    "t_stat" => {"Luck test (t)", :number},
    "max_drawdown" => {"Worst drop, trades added up", :share},
    "total_return" => {"Trades added up (whole account each)", :share},
    "account_return" => {"Account growth", :share},
    "account_max_drawdown" => {"Account's worst drop", :share},
    "expectancy" => {"Average trade", :share},
    "sharpe" => {"Sharpe per trade", :number},
    "annual_sharpe" => {"Sharpe (a year)", :number},
    "is_num_trades" => {"Trades on the data it was fitted to", :count},
    "oos_num_trades" => {"Trades on unseen data", :count},
    "is_num_months" => {"Months of results on the data it was fitted to", :count},
    "oos_num_months" => {"Months of results on unseen data", :count},
    "oos_return" => {"Trades added up on unseen data", :share},
    "oos_t_stat" => {"Luck test on unseen data (t)", :number},
    "oos_sharpe" => {"Sharpe per trade on unseen data", :number},
    "oos_annual_sharpe" => {"Sharpe (a year) on unseen data", :number},
    "sharpe_retention" => {"Quality kept on unseen data", :share},
    "profitable_pct" => {"Redrawn histories that made money", :share},
    "p95_drawdown" => {"Bad-run drop (1 in 20), trades added up", :share},
    "p95_drawdown_vs_hold" =>
      {"Bad run (1 in 20) at the risk of just holding, as a share of holding's own bad run",
       :share},
    "sharpe_vs_hold" => {"Sharpe above just holding's", :number},
    "median_sharpe" => {"Median Sharpe per trade", :number},
    "deflated_sharpe" => {"Chance it isn't luck from trying many versions", :share},
    "worst_sharpe_retention" => {"Sharpe kept at the worst nearby setting", :share},
    "worst_total_return" => {"Trades added up at the worst nearby setting", :share}
  }

  @operators %{"gte" => "at least", "gt" => "more than", "lte" => "at most", "lt" => "less than"}

  # "Trades 129 (needs at least 30)". Results saved since the engine values
  # open trades at every close (`drawdown_valued`) say so on their drops.
  defp check_words(%{metric: metric, operator: op, required: required, actual: actual}, stats) do
    {label, kind} = Map.get(@metrics, metric, {metric, :number})
    label = mc_label(metric, stats) || label

    label =
      if valued_every_close?(metric, stats), do: label <> ", valued at every close", else: label

    "#{label} #{value(actual, kind)} (needs #{@operators[op] || op} #{value(required, kind)})"
  end

  defp valued_every_close?(metric, %{"drawdown_valued" => "every_close"}),
    do: metric in ~w(max_drawdown account_max_drawdown)

  defp valued_every_close?(_metric, _stats), do: false

  # Monte Carlo's figures since it reshuffles the daily account
  # (`mc_method`): the drop is the account's at its own sizing.
  defp mc_label("p95_drawdown", %{"mc_method" => "daily_block_bootstrap"}),
    do: "Bad-run drop (1 in 20), account at its sizing, valued daily"

  defp mc_label("profitable_pct", %{"mc_method" => "daily_block_bootstrap"}),
    do: "Reshuffled daily histories that made money"

  defp mc_label(_metric, _stats), do: nil

  defp value(nil, _kind), do: "missing"
  defp value(v, :count), do: num(round(v))
  defp value(v, :share), do: pct(v)
  defp value(v, :number), do: num(v)

  # A ranked basket is judged on months of results; its few long-held
  # positions are context. The drop is the account's, valued at every close.
  defp backtest_line(%{
         stats: %{"judged_on" => "months", "account_return" => acc, "num_months" => m} = s
       }),
       do:
         copy(
           "Account %{account} over %{months} months of results (%{count} positions held across re-ranks); its worst drop, valued at every close, %{account_drop}",
           account: signed_pct(acc),
           months: m,
           count: s["num_trades"],
           account_drop: pct(s["account_max_drawdown"])
         )

  # The headline is the account: the trades one after another, each sized
  # at the strategy's risk, compounded. The figures the pass marks use
  # (trades added up at a whole account each) follow, named as such.
  defp backtest_line(%{
         stats: %{"account_return" => acc, "total_return" => r, "num_trades" => n} = s
       }),
       do:
         copy(
           "Account %{account} at %{risk} risk a trade, compounded; its worst drop %{account_drop}. %{count} trades, %{won} won. Trades added up: %{sum}, worst drop %{drop}",
           account: signed_pct(acc),
           risk: pct(s["account_risk_pct"]),
           account_drop: pct(s["account_max_drawdown"]),
           count: n,
           won: pct(s["win_rate"], 0),
           sum: signed_pct(r),
           drop: pct(s["max_drawdown"])
         )

  # Results saved before the account figures existed.
  defp backtest_line(%{stats: %{"total_return" => r, "num_trades" => n} = s}),
    do:
      copy(
        "Trades added up: %{sum} over %{count} trades, %{won} won, worst drop %{drop}",
        sum: signed_pct(r),
        count: n,
        won: pct(s["win_rate"], 0),
        drop: pct(s["max_drawdown"])
      )

  defp backtest_line(_), do: nil

  @doc """
  The costs a backtest charged, in words (its `costs`, recorded since the
  brokers table, Oct 30 2026): whose costs, what holding overnight cost,
  the spread and commission, and short rules skipped. Nil for older results
  and baskets.
  """
  @spec costs_words(map()) :: String.t() | nil
  def costs_words(%{stats: %{"costs" => %{"broker" => broker} = c}}) do
    overnight =
      case c["overnight"] do
        "oanda_financing" -> "overnight financing"
        _ -> "no overnight cost (shares owned outright)"
      end

    spread =
      case c["spread_bps"] do
        nil -> "the bid/ask spread on each fill"
        bps -> "a #{number(bps)} bp spread a trade"
      end

    commission =
      case c["commission_bps"] do
        bps when is_number(bps) and bps > 0 -> ", #{number(bps)} bp commission each way"
        _ -> ""
      end

    dividends =
      case {c["dividends_from"], c["dividends_recorded_since"]} do
        {"none", _} ->
          " The fund pays no dividends."

        {nil, "none"} ->
          " Dividends left out: there's no dividend history for this listing (our source " <>
            "covers US listings only), so results understate it by its yield, and just " <>
            "holding is compared the same way."

        {nil, since} when is_binary(since) ->
          " Dividends left out before #{since}: there's no dividend history for this listing, " <>
            "only the ones recorded since, so earlier results understate it by its yield."

        {nil, nil} ->
          ""

        {from, _} ->
          " Dividends paid to longs; tested from #{from}, where its dividend record starts."
      end

    shorts =
      if c["shorts_skipped"],
        do: " #{broker_name(broker)} can't short, so its short rules were skipped.",
        else: ""

    "Tested with #{broker_name(broker)}'s costs: #{overnight}, #{spread}#{commission}." <>
      dividends <> shorts
  end

  def costs_words(_stage), do: nil

  @doc """
  The backtest beside just holding the same funds over the same years
  (equal weights, dividends in, fully invested; recorded for shares held
  outright since Oct 30 2026): whether the rule beat holding on Sharpe,
  which compares fairly however much of the account it used. Nil when not
  recorded.
  """
  @spec hold_words(map()) :: String.t() | nil
  def hold_words(%{stats: %{"buy_and_hold" => %{"annual_sharpe" => hold} = h}})
      when is_number(hold) do
    # The rule's account valued every day, as holding is (not its
    # close-day Sharpe, which books a months-long hold all at once).
    mine = get_in(h, ["rule", "annual_sharpe"])

    verdict =
      cond do
        not is_number(mine) ->
          ""

        mine >= hold + 0.1 ->
          " This rule's Sharpe, #{number(mine, 2)}, beats it."

        mine <= hold - 0.1 ->
          " This rule's Sharpe, #{number(mine, 2)}, is worse: holding did better."

        true ->
          " This rule's Sharpe, #{number(mine, 2)}, is about the same: it added little."
      end

    "Just holding the same funds over the same years: #{signed_pct(h["total_return"])} " <>
      "(#{signed_pct(h["annual_return"])} a year), Sharpe #{number(hold, 2)}, worst drop " <>
      "#{pct(h["max_drawdown"])}, fully invested." <> verdict
  end

  def hold_words(_stage), do: nil

  defp number(n, decimals), do: :erlang.float_to_binary(n / 1, decimals: decimals)

  defp broker_name("oanda"), do: "OANDA"
  defp broker_name("wealthsimple"), do: "Wealthsimple"
  defp broker_name(other), do: other

  defp number(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp number(n), do: to_string(n)

  defp walk_forward_line(%{
         stats:
           %{
             "judged_on" => "months",
             "is_account_return" => is_acc,
             "oos_account_return" => oos_acc
           } = s
       }),
       do:
         copy(
           "fitted on older data: account %{is_account} over %{is_months} months; then on later data it hadn't seen: account %{oos_account} over %{oos_months} months",
           is_account: signed_pct(is_acc),
           is_months: s["is_num_months"],
           oos_account: signed_pct(oos_acc),
           oos_months: s["oos_num_months"]
         )

  defp walk_forward_line(%{
         stats:
           %{
             "is_account_return" => is_acc,
             "oos_account_return" => oos_acc,
             "is_return" => is,
             "oos_return" => oos
           } = s
       }),
       do:
         copy(
           "fitted on older data: account %{is_account} over %{is_count} trades (added up %{is_sum}); then on later data it hadn't seen: account %{oos_account} over %{oos_count} trades (added up %{oos_sum})",
           is_account: signed_pct(is_acc),
           is_count: s["is_num_trades"],
           is_sum: signed_pct(is),
           oos_account: signed_pct(oos_acc),
           oos_count: s["oos_num_trades"],
           oos_sum: signed_pct(oos)
         )

  defp walk_forward_line(%{stats: %{"is_return" => is, "oos_return" => oos} = s}),
    do:
      copy(
        "fitted on older data: trades added up %{is_sum} over %{is_count} trades; then on later data it hadn't seen: %{oos_sum} over %{oos_count} trades",
        is_sum: signed_pct(is),
        is_count: s["is_num_trades"],
        oos_sum: signed_pct(oos),
        oos_count: s["oos_num_trades"]
      )

  defp walk_forward_line(_), do: nil

  # Since Oct 30 the engine reshuffles stretches of the account's daily
  # results (`mc_method`); older results redrew trades or months one by one.
  defp monte_carlo_line(%{stats: %{"mc_method" => "daily_block_bootstrap"} = s}),
    do:
      "stretches of its daily account results reshuffled at random #{num(s["num_sims"], 0)} " <>
        "times: #{pct(s["profitable_pct"])} of those histories made money, and a bad run " <>
        "(1 in 20) falls #{pct(s["p95_drawdown"])} at its own sizing, open trades valued each day"

  defp monte_carlo_line(%{
         stats: %{"judged_on" => "months", "p95_drawdown" => dd, "profitable_pct" => made} = s
       }),
       do:
         "its months redrawn at random #{num(s["num_sims"], 0)} times: #{pct(made)} of those " <>
           "histories made money, and a bad run (1 in 20) falls #{pct(dd)} with the months added up"

  defp monte_carlo_line(%{stats: %{"p95_drawdown" => dd, "profitable_pct" => made} = s}),
    do:
      "its trades redrawn at random #{num(s["num_sims"], 0)} times: #{pct(made)} of those " <>
        "histories made money, and a bad run (1 in 20) falls #{pct(dd)} with the trades added up"

  defp monte_carlo_line(_), do: nil

  # The failure already names the setting that broke it; the checks alone
  # would only say the worst figure.
  defp parameter_stability_line(%{status: :failed, reason: reason, stats: %{"tested" => n}})
       when is_binary(reason),
       do: copy("%{count} nearby settings tried. %{reason}", count: n, reason: reason)

  defp parameter_stability_line(%{stats: %{"tested" => n, "worst_sharpe_retention" => kept}})
       when is_number(kept),
       do:
         copy("%{count} nearby settings tried; the weakest kept %{kept} of the Sharpe",
           count: n,
           kept: pct(kept, 0)
         )

  defp parameter_stability_line(_), do: nil

  defp live_words(%{trades: 0}), do: "No closed trades yet."

  defp live_words(%{trades: n, wins: wins, pnl: pnl, since: since}) do
    "#{n} closed #{if n == 1, do: "trade", else: "trades"} since #{date(since)}, " <>
      "#{wins} won, #{signed_money(pnl)} on the practice account"
  end

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
