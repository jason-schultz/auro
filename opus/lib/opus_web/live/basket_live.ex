defmodule OpusWeb.BasketLive do
  @moduledoc """
  Test one recipe on several markets at once (`Opus.Trading.Baskets`):

  1. **Pick the markets**: a ready-made group or any you tick, up to 40,
     on the recipe's timeframe (daily or 4-hour).
  2. **How to test them**: each on its own, together as one account, or
     ranked (buy the best, sell the worst, every so many bars).
  3. **Results**: every basket run of this recipe, newest first: what
     happened in a sentence, what to do next, the account's curve, each
     market's share of it, and every stage with the rules it was judged on.

  A basket is tested, never traded live: there's no switch to turn on.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.ResultCharts, only: [account_curve: 1]

  import OpusWeb.StrategyParts,
    only: [evidence: 1, field: 1, luck_check: 1, resume: 1, stat: 1, test_badge: 1]

  alias Opus.Pipeline.Events
  alias Opus.Trading.{Baskets, Recipes, StrategyResults, StrategyWords}

  @impl true
  def mount(%{"recipe_id" => id}, _session, socket) do
    case Recipes.get(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "No such strategy.") |> push_navigate(to: ~p"/strategies")}

      recipe ->
        if connected?(socket), do: Events.subscribe(recipe.definition, recipe.granularity)

        markets =
          if Baskets.timeframe_ok?(recipe.granularity),
            do: Baskets.markets(recipe.granularity),
            else: []

        choices = Baskets.rank_choices(recipe.definition)

        {:ok,
         socket
         |> assign(
           page_title: "#{recipe.name} on several markets",
           recipe: recipe,
           markets: markets,
           selected: [],
           mode: "together",
           rank: %{
             "by" => choices |> List.first({nil, nil}) |> elem(0),
             "every_bars" => to_string(Baskets.monthly_bars(recipe.granularity)),
             "long_top" => "3",
             "short_bottom" => "3",
             "buy" => "highest"
           },
           rank_choices: choices,
           error: nil
         )
         |> load_runs()}
    end
  end

  defp load_runs(%{assigns: %{recipe: recipe}} = socket) do
    runs = StrategyResults.for_baskets(recipe.definition, recipe.granularity)
    assign(socket, runs: runs, busy: busy?(runs))
  end

  defp busy?(runs),
    do:
      Enum.any?(runs, fn run ->
        Enum.any?(Map.values(run.stages), &(&1.status in [:running, :pending]))
      end)

  # A pipeline stage started or finished (`Opus.Pipeline.Events`): each
  # result shows the moment it lands.
  @impl true
  def handle_info({:pipeline_stage, _config_id}, socket), do: {:noreply, load_runs(socket)}

  @impl true
  def handle_event("preset", %{"id" => id}, socket) do
    picked = socket.assigns.markets |> Baskets.preset(id) |> Enum.take(Baskets.max_markets())
    {:noreply, assign(socket, selected: picked, error: nil)}
  end

  def handle_event("clear", _params, socket), do: {:noreply, assign(socket, selected: [])}

  def handle_event("change", params, socket) do
    {:noreply,
     assign(socket,
       selected: Map.get(params, "markets", []) |> Enum.reject(&(&1 == "")),
       mode: Map.get(params, "mode", socket.assigns.mode),
       rank: Map.merge(socket.assigns.rank, Map.get(params, "rank", %{})),
       error: nil
     )}
  end

  def handle_event("submit", _params, socket) do
    %{recipe: recipe, selected: selected, mode: mode, rank: rank} = socket.assigns

    case Baskets.submit(recipe, selected, %{"mode" => mode, "rank" => rank}) do
      {:ok, configs} ->
        message =
          if mode == "separate",
            do:
              "The tests are running on #{length(configs)} markets, each on its own. Their results show on the strategy's page.",
            else:
              "The basket test is running. Each stage's result shows below as it finishes; the page updates by itself."

        {:noreply, socket |> put_flash(:info, message) |> load_runs()}

      {:error, words} ->
        {:noreply, assign(socket, error: words)}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_runs(socket)}

  def handle_event("resume_stage", params, socket) do
    {kind, words} = resume(params)
    {:noreply, socket |> put_flash(kind, words) |> load_runs()}
  end

  @stage_words [
    backtest: "backtest",
    walk_forward: "walk-forward test",
    monte_carlo: "Monte Carlo test",
    parameter_stability: "nearby-settings test",
    holdout: "holdout"
  ]

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        groups: Enum.group_by(assigns.markets, & &1.asset_class, & &1.symbol),
        timeframe: StrategyWords.timeframe(assigns.recipe.granularity),
        testable: Baskets.timeframe_ok?(assigns.recipe.granularity),
        over: length(assigns.selected) > Baskets.max_markets()
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <div class="flex flex-col gap-3">
          <.link
            navigate={~p"/strategies"}
            class="self-start text-[13px] text-muted hover:text-base-content"
          >
            ← <.t {copy("Strategies")} />
          </.link>
          <div class="flex flex-col gap-1">
            <h1 class="text-[24px] font-semibold leading-tight tracking-tight">{@recipe.name}</h1>
            <span class="text-[14px] text-muted">
              <span class="font-medium text-base-content">
                <.t {copy("Test it on several markets")} />
              </span>
              · {@timeframe} · tested only, never traded live
            </span>
          </div>
          <p class="m-0 max-w-[760px] text-[14px] text-muted">
            Some ideas only work across many markets at once: hold every market sized to the same
            risk, or rank them and hold the best against the worst. Here the strategy runs on a
            basket of markets as one account, judged by the same tests and pass marks as on one market.
          </p>
          <div class="flex flex-wrap gap-2">
            <.link
              navigate={~p"/strategies/recipes/#{@recipe.id}/edit"}
              class="inline-flex min-h-11 items-center rounded-field border border-base-300 px-3.5 text-[14px] font-medium hover:border-primary"
            >
              <.t {copy("Edit the rules")} />
            </.link>
            <.link
              navigate={~p"/strategies/recipes/#{@recipe.id}/edit?copy=1"}
              class="inline-flex min-h-11 items-center rounded-field border border-base-300 px-3.5 text-[14px] font-medium hover:border-primary"
            >
              <.t {copy("Copy as a new strategy")} />
            </.link>
          </div>
        </div>

        <p
          :if={not @testable}
          role="alert"
          class="m-0 rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          Baskets are tested on daily or 4-hour bars only, and this strategy uses {@timeframe}.
          Copy it as a new strategy on daily bars to test it this way.
        </p>

        <form
          :if={@testable}
          id="basket-form"
          phx-change="change"
          phx-submit="submit"
          class="flex flex-col gap-6 lg:grid lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)] lg:items-start"
        >
          <section
            aria-labelledby="markets-h"
            class="flex min-w-0 flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <h2 id="markets-h" class="text-[15px] font-semibold">
                <span class="text-muted">1 ·</span> <.t {copy("Pick the markets")} />
              </h2>
              <span
                aria-live="polite"
                class={["text-[13px]", if(@over, do: "font-medium text-error", else: "text-muted")]}
              >
                {length(@selected)} picked, up to {Baskets.max_markets()}
              </span>
            </div>
            <p class="m-0 text-[14px] text-muted">
              Start from a ready-made group, then tick or untick any market.
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                :for={p <- Baskets.presets()}
                type="button"
                phx-click="preset"
                phx-value-id={p.id}
                class="min-h-11 rounded-field border border-base-300 bg-base-100 px-3.5 text-[14px] font-medium hover:border-primary"
              >
                {p.label}
              </button>
              <button
                :if={@selected != []}
                type="button"
                phx-click="clear"
                class="min-h-11 px-2 text-[14px] text-muted hover:text-base-content"
              >
                Clear
              </button>
            </div>
            <p :if={@markets == []} class="m-0 text-[14px] text-muted">
              No market has {@timeframe} stored from before the holdout, so there's nothing to test on yet.
            </p>
            <input type="hidden" name="markets[]" value="" />
            <fieldset
              :for={{class, symbols} <- @groups}
              class="m-0 flex min-w-0 flex-col gap-1 rounded-field border border-base-300 bg-base-100 px-4 pb-2 pt-3"
            >
              <legend class="float-left flex w-full flex-wrap items-baseline justify-between gap-x-3 text-[13px]">
                <span class="font-semibold">{Baskets.class_name(class)}</span>
                <span class="text-muted">
                  {Enum.count(symbols, &(&1 in @selected))} of {length(symbols)}
                </span>
              </legend>
              <div class="grid grid-cols-[repeat(auto-fill,minmax(7.25rem,1fr))] gap-x-3">
                <label :for={s <- symbols} class="inline-flex min-h-9 items-center gap-2 text-[14px]">
                  <input
                    type="checkbox"
                    name="markets[]"
                    value={s}
                    checked={s in @selected}
                    class="checkbox checkbox-sm"
                  />
                  <span class={if s in @selected, do: "font-medium", else: "text-muted"}>{s}</span>
                </label>
              </div>
            </fieldset>
          </section>

          <div class="flex min-w-0 flex-col gap-4 lg:sticky lg:top-24">
            <section
              aria-labelledby="mode-h"
              class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
            >
              <h2 id="mode-h" class="text-[15px] font-semibold">
                <span class="text-muted">2 ·</span> <.t {copy("How to test them")} />
              </h2>
              <div class="flex flex-col gap-2">
                <label
                  :for={{value, title, words} <- modes()}
                  class={[
                    "flex min-h-11 cursor-pointer items-start gap-3 rounded-field border px-4 py-3",
                    if(@mode == value,
                      do: "border-primary bg-primary/10",
                      else: "border-base-300 bg-base-100 hover:border-primary"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    name="mode"
                    value={value}
                    checked={@mode == value}
                    class="radio radio-sm mt-0.5"
                  />
                  <span class="flex flex-col gap-0.5">
                    <span class="text-[14px] font-semibold">{title}</span>
                    <span class="text-[13px] text-muted">{words}</span>
                  </span>
                </label>
              </div>

              <div
                :if={@mode == "ranked"}
                class="flex flex-col gap-3 rounded-field border border-base-300 bg-base-100 px-4 py-3"
              >
                <span class="text-[14px] font-semibold">Ranking</span>
                <p :if={@rank_choices == []} class="m-0 text-[14px] text-warning">
                  None of this strategy's blocks shows a value to rank by. Add one that does, like
                  Momentum (its past return) or Carry (its rate gap).
                </p>
                <div :if={@rank_choices != []} class="flex flex-col gap-3">
                  <.field label="Rank the markets by">
                    <select name="rank[by]" class="select w-full">
                      <option
                        :for={{value, label} <- @rank_choices}
                        value={value}
                        selected={@rank["by"] == value}
                      >
                        {label}
                      </option>
                    </select>
                  </.field>
                  <.field label="Which end to buy">
                    <select name="rank[buy]" class="select w-full">
                      <option value="highest" selected={@rank["buy"] != "lowest"}>
                        The highest (follow the winners, like momentum or carry)
                      </option>
                      <option value="lowest" selected={@rank["buy"] == "lowest"}>
                        The lowest (buy the losers, a short-term reversal)
                      </option>
                    </select>
                  </.field>
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(110px,1fr))] gap-3">
                    <.field
                      label="Re-rank every (bars)"
                      help={"#{Baskets.monthly_bars(@recipe.granularity)} is about a month"}
                    >
                      <input
                        type="number"
                        min="1"
                        name="rank[every_bars]"
                        value={@rank["every_bars"]}
                        class="input w-full"
                      />
                    </.field>
                    <.field label={
                      if @rank["buy"] == "lowest", do: "Buy the bottom", else: "Buy the top"
                    }>
                      <input
                        type="number"
                        min="0"
                        name="rank[long_top]"
                        value={@rank["long_top"]}
                        class="input w-full"
                      />
                    </.field>
                    <.field label={
                      if @rank["buy"] == "lowest", do: "Sell the top", else: "Sell the bottom"
                    }>
                      <input
                        type="number"
                        min="0"
                        name="rank[short_bottom]"
                        value={@rank["short_bottom"]}
                        class="input w-full"
                      />
                    </.field>
                  </div>
                </div>
                <p class="m-0 text-[12px] text-muted">
                  The strategy's buy and sell rules aren't used here: the ranking decides. Its stop
                  only sets each position's size, so a stop based on ATR (how much the market moves)
                  gives every market the same risk, as the papers do. Positions are held to the next re-rank.
                </p>
              </div>
            </section>

            <section
              aria-labelledby="run-h"
              class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
            >
              <h2 id="run-h" class="text-[15px] font-semibold">
                <span class="text-muted">3 ·</span> <.t {copy("What happens when you run it")} />
              </h2>
              <ol class="m-0 flex list-decimal flex-col gap-1 pl-5 text-[14px] text-muted">
                <li :for={line <- run_steps(@mode)}>{line}</li>
              </ol>
              <p
                :if={@error}
                role="alert"
                class="m-0 rounded-field border border-warning/40 bg-base-100 px-3 py-2 text-[13px]"
              >
                {@error}
              </p>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <button
                  type="submit"
                  disabled={@selected == [] or @over}
                  class="min-h-11 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Run the tests
                </button>
                <span class={["text-[13px]", if(@over, do: "text-error", else: "text-muted")]}>
                  {submit_hint(length(@selected))}
                </span>
              </div>
            </section>
          </div>
        </form>

        <section
          id="results"
          aria-labelledby="runs-h"
          class="flex scroll-mt-24 flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h2 id="runs-h" class="text-[15px] font-semibold">
              <.t {copy("Basket results")} />
            </h2>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
              <span :if={@busy} class="text-[13px] text-muted">
                Running: each result shows here as it lands
              </span>
              <button
                type="button"
                phx-click="refresh"
                class="min-h-11 rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary"
              >
                Check for new results
              </button>
            </div>
          </div>
          <p :if={@runs == []} class="m-0 text-[14px] text-muted">
            No basket test of this strategy yet. Pick markets above and run the tests.
          </p>
          <.run
            :for={{run, i} <- Enum.with_index(@runs)}
            run={run}
            open={i == 0}
            every={valued_every(@recipe.granularity)}
            choices={@rank_choices}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp modes do
    [
      {"separate", "Each market on its own",
       "One test per market, as if you'd tested them one at a time. Results show on the strategy's page."},
      {"together", "Together as one account",
       "Every market trades the strategy's own rules at once, each trade sized the way it would trade live, on one account. The tests judge the account."},
      {"ranked", "Ranked: hold the best against the worst",
       "Every so many bars, rank the markets by a value the strategy shows, buy the top ones and sell the bottom ones until the next re-rank. One account."}
    ]
  end

  @stages_line "backtest, walk-forward, Monte Carlo, nearby settings, then the holdout (a one-time look at data kept aside)."

  defp run_steps("separate"),
    do: [
      "Each picked market gets its own tests: " <> @stages_line,
      "Each result shows on the strategy's page, like any market you test it on.",
      "Nothing trades until you switch a market on there."
    ]

  defp run_steps(_one_account),
    do: [
      "The picked markets run as one account through the tests: " <> @stages_line,
      "The result shows below as each stage finishes.",
      "A basket is tested only: there's nothing to switch on."
    ]

  defp submit_hint(0), do: "Pick at least one market."

  defp submit_hint(n) do
    max = Baskets.max_markets()

    if n > max,
      do: "That's #{n}: untick #{n - max} to get to #{max}.",
      else: "#{n} #{if n == 1, do: "market", else: "markets"} picked."
  end

  attr :run, :map, required: true
  attr :open, :boolean, default: false
  attr :every, :string, required: true, doc: "how often the account is valued, in words"
  attr :choices, :list, default: [], doc: "Baskets.rank_choices/1, to name the ranked value"

  defp run(assigns) do
    assigns =
      assign(assigns,
        account: Baskets.account(assigns.run),
        outcome: outcome(assigns.run.stages)
      )

    ~H"""
    <details
      open={@open}
      class="rounded-field bg-base-100 px-4 py-2.5"
      id={"basket-#{@run.config_id}"}
    >
      <summary class="flex min-h-9 cursor-pointer flex-wrap items-baseline gap-x-3 gap-y-0.5">
        <span class="font-medium">{length(@run.basket["markets"])} markets</span>
        <span class="text-[13px] text-muted">{mode_short(@run.basket)}</span>
        <.test_badge results={@run.stages} />
        <span class="text-[13px] text-muted sm:ml-auto">{stamp(@run.ran_at)}</span>
      </summary>
      <div class="flex flex-col gap-4 pb-2 pt-3">
        <div class={[
          "flex flex-col gap-1.5 rounded-field border bg-base-200 px-4 py-3",
          outcome_border(@outcome)
        ]}>
          <p class="m-0 text-[15px] font-medium">{headline(@run, @account, @every)}</p>
          <p class="m-0 text-[14px]">
            <span class={["font-semibold", outcome_text(@outcome)]}>What to do next:</span>
            <span class="text-muted">{next_step(@run.stages)}</span>
          </p>
        </div>

        <dl
          :if={@account}
          class="m-0 grid grid-cols-2 gap-x-4 gap-y-3.5 sm:grid-cols-4"
        >
          <.stat
            label={copy("Account growth")}
            value={signed_pct(@account.stats["account_return"], 1)}
            class={tone(@account.stats["account_return"])}
          />
          <.stat
            label={copy("A year")}
            value={signed_pct(get_in(@account.stats, ["basket", "annual_return"]), 1)}
          />
          <.stat
            label={copy("Worst drop")}
            value={pct(@account.stats["account_max_drawdown"], 1)}
          />
          <.stat
            :if={is_integer(@account.stats["num_months"])}
            label={copy("Months of results")}
            value={to_string(@account.stats["num_months"])}
          />
          <.stat
            :if={!is_integer(@account.stats["num_months"])}
            label={copy("Trades")}
            value={to_string(@account.stats["num_trades"] || "—")}
          />
        </dl>

        <p class="m-0 break-words text-[13px] text-muted">
          <span class="font-medium text-base-content">{Baskets.mode_words(@run.basket, @choices)}.</span>
          {Enum.join(@run.basket["markets"], ", ")}
        </p>

        <div
          :if={@account && @account.curve != []}
          class="flex flex-col gap-2 border-t border-neutral pt-4"
        >
          <h3 class="text-[14px] font-semibold">
            The account over time{if @account.holdout?, do: " (holdout)", else: ""}
          </h3>
          <.account_curve
            without_rules={%{points: @account.curve, total_return: @account.stats["account_return"]}}
            from={@account.from}
            to={@account.to}
            label="The account"
          />
        </div>

        <div :if={@account} class="flex flex-col gap-2 border-t border-neutral pt-4">
          <h3 class="text-[14px] font-semibold">What each market added</h3>
          <p class="m-0 text-[13px] text-muted">{carry_words(@account.by_market)}</p>
          <div :if={@account.by_market != []} class="overflow-x-auto">
            <table class="w-full min-w-[420px] border-collapse text-sm">
              <thead>
                <tr class="text-left text-xs text-muted">
                  <th class="border-b border-base-300 py-2 font-medium">Market</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Trades</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Winners</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">
                    Added to the account
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={m <- @account.by_market} class="border-b border-neutral last:border-b-0">
                  <td class="py-2">{m.market}</td>
                  <td class="py-2 text-right">{m.trades}</td>
                  <td class="py-2 text-right">{m.wins}</td>
                  <td class={["py-2 text-right", tone(m.account_return)]}>
                    {signed_pct(m.account_return, 1)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="m-0 text-[12px] text-muted">
            Each market's trades added up as shares of the account at the time, so they sum to
            about the account's return (before compounding).
          </p>
        </div>

        <div class="flex flex-col gap-2 border-t border-neutral pt-4">
          <h3 class="text-[14px] font-semibold">Each test, and the rules it was judged on</h3>
          <.evidence results={@run.stages} />
          <.luck_check walk_forward={@run.stages.walk_forward} />
          <p class="m-0 text-[12px] text-muted">
            For a basket every figure is the account's: each trade counts as what it did to the
            account, so "trades added up" and the drop are the account's own. The luck check counts
            this basket as one try among the baskets of the same idea.
          </p>
          <p :if={@account} class="m-0 text-[12px] text-muted">
            {drop_note(@account.stats, @every)}
          </p>
          <p :if={Baskets.by_months?(@run)} class="m-0 text-[12px] text-muted">
            A ranked basket keeps its positions from one re-rank to the next, so one position held
            for years is a single "trade" and a trade count says little. It's judged the way the
            research papers judge these books: on the account's return each calendar month. The
            luck test, the Sharpe, the luck check and the redrawn histories all use those months,
            and it needs enough months of results instead of enough trades.
          </p>
        </div>
      </div>
    </details>
    """
  end

  defp mode_short(%{"mode" => "ranked"}), do: "ranked"
  defp mode_short(_together), do: "as one account"

  # Where the stages stand, for the verdict box's colour.
  defp outcome(stages) do
    statuses = Enum.map(Keyword.keys(@stage_words), &stages[&1].status)

    cond do
      :failed in statuses -> :failed
      Enum.any?(statuses, &(&1 in [:running, :pending, :stuck])) -> :waiting
      stages.holdout.status == :passed -> :passed
      true -> :waiting
    end
  end

  defp outcome_border(:failed), do: "border-error/40"
  defp outcome_border(:passed), do: "border-success/40"
  defp outcome_border(:waiting), do: "border-base-300"

  defp outcome_text(:failed), do: "text-error"
  defp outcome_text(:passed), do: "text-success"
  defp outcome_text(:waiting), do: "text-warning"

  defp headline(run, nil, _every),
    do:
      "Testing #{length(run.basket["markets"])} markets as one account. The result shows here when the backtest finishes."

  defp headline(run, account, every) do
    stats = account.stats
    where = if account.holdout?, do: " in the holdout (data the other tests never saw)", else: ""

    "On #{length(run.basket["markets"])} markets as one account#{where}, it made " <>
      "#{signed_pct(stats["account_return"], 1)} " <>
      "(#{signed_pct(stats["basket"]["annual_return"], 1)} a year) from " <>
      "#{date(account.from)} to #{date(account.to)} over #{span_words(stats)}, " <>
      "and fell at worst #{pct(stats["account_max_drawdown"], 1)} below its best" <>
      valued_words(stats, every) <> "."
  end

  # A ranked basket is judged on months; its trades are context.
  defp span_words(%{"num_months" => months, "num_trades" => trades}) when is_integer(months),
    do: "#{months} months of results (#{trades} positions held across re-ranks)"

  defp span_words(stats), do: "#{stats["num_trades"]} trades"

  defp drop_note(%{"drawdown_valued" => "every_close"}, every),
    do:
      "The worst drop is valued #{every} with open positions at their latest price, so a " <>
        "position that dipped and came back before it closed still shows its dip."

  defp drop_note(_stats, _every),
    do:
      "This run's worst drop was valued only as trades closed, so it misses dips in positions " <>
        "that recovered before closing. Run the tests again to see the drop valued every day."

  # Results saved before the engine valued open positions at every close
  # were valued only as trades closed: say nothing rather than claim it.
  defp valued_words(%{"drawdown_valued" => "every_close"}, every),
    do: " (valued #{every}, open positions included)"

  defp valued_words(_stats, _every), do: ""

  defp valued_every("H4"), do: "every 4 hours"
  defp valued_every(_daily), do: "every day"

  # What to do now, from where the stages stand.
  defp next_step(stages) do
    failed = Enum.find(@stage_words, fn {key, _} -> stages[key].status == :failed end)

    stuck = Enum.find(@stage_words, fn {key, _} -> stages[key].status == :stuck end)

    waiting =
      Enum.find(@stage_words, fn {key, _} -> stages[key].status in [:running, :pending] end)

    cond do
      failed ->
        {key, words} = failed

        "It failed the #{words}#{reason(stages[key].reason)}. As tested, this basket shows no edge: " <>
          "try a different idea or set of markets rather than tweaking settings until it passes."

      stuck ->
        "The #{elem(stuck, 1)} stopped part-way and nothing is running it. Resume it from its " <>
          "line below."

      waiting ->
        "The #{elem(waiting, 1)} is running or waiting. Nothing to do yet: this page shows each " <>
          "result as it lands."

      Enum.any?(Map.values(stages), &(&1.status in [:old_pass, :old_fail])) ->
        "It was judged by older rules. Run the tests again to see where it stands by today's."

      stages.holdout.status == :passed ->
        "It passed every test, the holdout too. Baskets aren't traded live yet, so there's nothing " <>
          "to switch on: note it as a real candidate."

      true ->
        "Not finished."
    end
  end

  defp reason(nil), do: ""
  defp reason(text), do: ": " <> text

  defp carry_words([]), do: "No trades yet."

  defp carry_words(rows) do
    best = List.first(rows)
    worst = List.last(rows)
    makers = Enum.count(rows, &(&1.account_return > 0))

    "#{makers} of #{length(rows)} markets made money. #{best.market} added the most " <>
      "(#{signed_pct(best.account_return, 1)}); #{worst.market} cost the most " <>
      "(#{signed_pct(worst.account_return, 1)})."
  end
end
