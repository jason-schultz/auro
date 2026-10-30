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
  import OpusWeb.StrategyParts, only: [evidence: 1, luck_check: 1, test_badge: 1]

  alias Opus.Trading.{Baskets, Recipes, StrategyResults, StrategyWords}

  @impl true
  def mount(%{"recipe_id" => id}, _session, socket) do
    case Recipes.get(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "No such strategy.") |> push_navigate(to: ~p"/strategies")}

      recipe ->
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
             "short_bottom" => "3"
           },
           rank_choices: choices,
           error: nil
         )
         |> load_runs()}
    end
  end

  defp load_runs(%{assigns: %{recipe: recipe}} = socket),
    do: assign(socket, runs: StrategyResults.for_baskets(recipe.definition, recipe.granularity))

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
            else: "The basket test is running. Its result shows below as each stage finishes."

        {:noreply, socket |> put_flash(:info, message) |> load_runs()}

      {:error, words} ->
        {:noreply, assign(socket, error: words)}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_runs(socket)}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        groups: Enum.group_by(assigns.markets, & &1.asset_class, & &1.symbol),
        timeframe: StrategyWords.timeframe(assigns.recipe.granularity),
        over: length(assigns.selected) > Baskets.max_markets()
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex max-w-[1120px] flex-col gap-7">
        <header class="flex flex-col gap-1.5">
          <.link
            navigate={~p"/strategies/recipes/#{@recipe.id}/edit"}
            class="self-start text-[14px] text-muted hover:text-base-content"
          >
            ← {@recipe.name}
          </.link>
          <h1 class="text-[32px] font-bold tracking-tight">Test it on several markets</h1>
          <p class="m-0 max-w-[720px] text-[16px] text-muted">
            Some ideas only work across many markets at once: hold every market sized to the same
            risk, or rank them and hold the best against the worst. Here {@recipe.name} ({@timeframe}) runs on a basket of markets as one account, judged by the same tests
            and pass marks as on one market. Baskets are tested only, not traded live.
          </p>
        </header>

        <p
          :if={not Baskets.timeframe_ok?(@recipe.granularity)}
          role="alert"
          class="m-0 rounded-box border border-warning/40 bg-base-200 px-5 py-4 text-[14px]"
        >
          Baskets are tested on daily or 4-hour bars only, and this strategy uses {@timeframe}.
          Save a copy on daily bars to test it this way.
        </p>

        <form
          :if={Baskets.timeframe_ok?(@recipe.granularity)}
          id="basket-form"
          phx-change="change"
          phx-submit="submit"
          class="flex flex-col gap-5"
        >
          <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <h2 class="text-[18px] font-semibold">1 · Pick the markets</h2>
              <span class={["text-[14px]", if(@over, do: "text-error", else: "text-muted")]}>
                {length(@selected)} picked, up to {Baskets.max_markets()}
              </span>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={p <- Baskets.presets()}
                type="button"
                phx-click="preset"
                phx-value-id={p.id}
                class="min-h-11 rounded-field border border-base-300 px-3.5 text-[14px] hover:border-primary"
              >
                {p.label}
              </button>
              <button
                type="button"
                phx-click="clear"
                class="min-h-11 px-3 text-[14px] text-muted hover:text-base-content"
              >
                Clear
              </button>
            </div>
            <p :if={@markets == []} class="m-0 text-[14px] text-muted">
              No market has {@timeframe} bars from before the holdout, so there's nothing to test on yet.
            </p>
            <input type="hidden" name="markets[]" value="" />
            <fieldset :for={{class, symbols} <- @groups} class="flex flex-col gap-1.5">
              <legend class="pb-1 text-[13px] font-medium text-muted">
                {Baskets.class_name(class)}
              </legend>
              <div class="flex flex-wrap gap-x-4 gap-y-1">
                <label :for={s <- symbols} class="inline-flex min-h-9 items-center gap-2 text-[14px]">
                  <input
                    type="checkbox"
                    name="markets[]"
                    value={s}
                    checked={s in @selected}
                    class="checkbox checkbox-sm"
                  />
                  {s}
                </label>
              </div>
            </fieldset>
          </section>

          <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <h2 class="text-[18px] font-semibold">2 · How to test them</h2>
            <div class="flex flex-col gap-2">
              <label :for={{value, title, words} <- modes()} class="flex items-start gap-2.5">
                <input
                  type="radio"
                  name="mode"
                  value={value}
                  checked={@mode == value}
                  class="radio radio-sm mt-0.5"
                />
                <span class="flex flex-col">
                  <span class="text-[14px] font-medium">{title}</span>
                  <span class="text-[13px] text-muted">{words}</span>
                </span>
              </label>
            </div>

            <div
              :if={@mode == "ranked"}
              class="flex flex-col gap-3 rounded-field border border-base-300 bg-base-100 px-4 py-3"
            >
              <p :if={@rank_choices == []} class="m-0 text-[14px] text-warning">
                None of this strategy's blocks shows a value to rank by. Add one that does, like
                Momentum (its past return) or Carry (its rate gap).
              </p>
              <div :if={@rank_choices != []} class="flex flex-wrap gap-4">
                <label class="flex flex-col gap-1 text-[13px] text-muted">
                  Rank the markets by
                  <select name="rank[by]" class="select select-sm w-auto">
                    <option
                      :for={{value, label} <- @rank_choices}
                      value={value}
                      selected={@rank["by"] == value}
                    >
                      {label}
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1 text-[13px] text-muted">
                  Re-rank every (bars)
                  <input
                    type="number"
                    min="1"
                    name="rank[every_bars]"
                    value={@rank["every_bars"]}
                    class="input input-sm w-28"
                  />
                </label>
                <label class="flex flex-col gap-1 text-[13px] text-muted">
                  Buy the top
                  <input
                    type="number"
                    min="0"
                    name="rank[long_top]"
                    value={@rank["long_top"]}
                    class="input input-sm w-24"
                  />
                </label>
                <label class="flex flex-col gap-1 text-[13px] text-muted">
                  Sell the bottom
                  <input
                    type="number"
                    min="0"
                    name="rank[short_bottom]"
                    value={@rank["short_bottom"]}
                    class="input input-sm w-24"
                  />
                </label>
              </div>
              <p class="m-0 text-[12px] text-muted">
                {Baskets.monthly_bars(@recipe.granularity)} bars is about a month. The strategy's
                buy and sell rules aren't used here: the ranking decides. Its stop only sets each
                position's size, so a stop based on ATR (how much the market moves) gives every
                market the same risk, as the papers do. Positions are held to the next re-rank.
              </p>
            </div>

            <p
              :if={@error}
              role="alert"
              class="m-0 rounded-field border border-error/40 bg-base-100 px-3 py-2 text-[14px]"
            >
              {@error}
            </p>
            <div>
              <button
                type="submit"
                disabled={@selected == [] or @over}
                class="min-h-11 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Run the tests
              </button>
            </div>
          </section>
        </form>

        <section aria-labelledby="runs-h" class="flex flex-col gap-3">
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h2 id="runs-h" class="text-[22px] font-bold">3 · Basket results</h2>
            <button
              type="button"
              phx-click="refresh"
              class="min-h-11 text-[14px] font-medium text-primary hover:brightness-110"
            >
              Check for new results
            </button>
          </div>
          <p :if={@runs == []} class="m-0 text-[14px] text-muted">
            No basket test of this strategy yet. Pick markets above and run the tests.
          </p>
          <.run
            :for={{run, i} <- Enum.with_index(@runs)}
            run={run}
            open={i == 0}
            every={valued_every(@recipe.granularity)}
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

  attr :run, :map, required: true
  attr :open, :boolean, default: false
  attr :every, :string, required: true, doc: "how often the account is valued, in words"

  defp run(assigns) do
    assigns = assign(assigns, account: Baskets.account(assigns.run))

    ~H"""
    <details
      open={@open}
      class="rounded-box border border-base-300 bg-base-200 px-5 py-3"
      id={"basket-#{@run.config_id}"}
    >
      <summary class="flex min-h-9 cursor-pointer flex-wrap items-baseline gap-x-3">
        <span class="font-medium">{length(@run.basket["markets"])} markets</span>
        <.test_badge results={@run.stages} />
        <span class="text-[13px] text-muted">{stamp(@run.ran_at)}</span>
      </summary>
      <div class="flex flex-col gap-4 pt-3">
        <div class="flex flex-col gap-1.5 rounded-field border border-primary bg-base-100 px-4 py-3">
          <p class="m-0 text-[16px] font-medium">{headline(@run, @account, @every)}</p>
          <p class="m-0 text-[14px] text-muted">{next_step(@run.stages)}</p>
        </div>
        <p class="m-0 text-[13px] text-muted">
          {Baskets.mode_words(@run.basket)} · {Enum.join(@run.basket["markets"], ", ")}
        </p>

        <div :if={@account && @account.curve != []} class="flex flex-col gap-2">
          <span class="text-[14px] font-semibold">
            The account over time{if @account.holdout?, do: " (holdout)", else: ""}
          </span>
          <.account_curve
            without_rules={%{points: @account.curve, total_return: @account.stats["account_return"]}}
            from={@account.from}
            to={@account.to}
          />
        </div>

        <div :if={@account} class="flex flex-col gap-2">
          <span class="text-[14px] font-semibold">What each market added</span>
          <span class="text-[13px] text-muted">{carry_words(@account.by_market)}</span>
          <table class="w-full text-[14px]">
            <thead>
              <tr class="text-left text-[13px] text-muted">
                <th class="py-1 font-normal">Market</th>
                <th class="py-1 text-right font-normal">Trades</th>
                <th class="py-1 text-right font-normal">Winners</th>
                <th class="py-1 text-right font-normal">Added to the account</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={m <- @account.by_market} class="border-t border-neutral">
                <td class="py-1">{m.market}</td>
                <td class="py-1 text-right tabular-nums">{m.trades}</td>
                <td class="py-1 text-right tabular-nums">{m.wins}</td>
                <td class={["py-1 text-right tabular-nums", tone(m.account_return)]}>
                  {signed_pct(m.account_return, 1)}
                </td>
              </tr>
            </tbody>
          </table>
          <p class="m-0 text-[12px] text-muted">
            Each market's trades added up as shares of the account at the time, so they sum to
            about the account's return (before compounding).
          </p>
        </div>

        <div class="flex flex-col gap-2">
          <span class="text-[14px] font-semibold">Each test, and the rules it was judged on</span>
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

  @stage_words [
    backtest: "backtest",
    walk_forward: "walk-forward test",
    monte_carlo: "Monte Carlo test",
    parameter_stability: "nearby-settings test",
    holdout: "holdout"
  ]

  # What to do now, from where the stages stand.
  defp next_step(stages) do
    failed = Enum.find(@stage_words, fn {key, _} -> stages[key].status == :failed end)

    waiting =
      Enum.find(@stage_words, fn {key, _} -> stages[key].status in [:running, :pending] end)

    cond do
      failed ->
        {key, words} = failed

        "It failed the #{words}#{reason(stages[key].reason)}. As tested, this basket shows no edge: " <>
          "try a different idea or set of markets rather than tweaking settings until it passes."

      waiting ->
        "The #{elem(waiting, 1)} is running or waiting. Nothing to do yet; check back for the next result."

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
