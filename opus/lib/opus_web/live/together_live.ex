defmodule OpusWeb.TogetherLive do
  @moduledoc """
  Strategies backtested together on one account (`Opus.Trading.Together`):
  pick plays (your switched-on strategies to start), run them, and read what
  the account would have done with your safety rules and without them, each
  play alone over the same years, and how alike they move. Then pick one
  and find it a companion: the plays that steady it most, best first.

  Both runs backtest every play in the engine, so they run after the click
  and the page says so while they do.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.ResultCharts, only: [account_curve: 1]

  alias Opus.Auro.Client
  alias Opus.Trading.{AccountLimits, Together}

  @shown_companions 10

  @impl true
  def mount(_params, _session, socket) do
    choices = Together.choices()

    socket =
      assign(socket,
        page_title: "Together",
        choices: choices,
        selected: choices.yours |> Enum.filter(& &1.enabled) |> MapSet.new(& &1.key),
        running: false,
        result: nil,
        error: nil,
        base: Enum.find_value(choices.yours, &(&1.enabled && &1.key)),
        finding: false,
        companions: nil,
        companion_error: nil,
        limits: AccountLimits.get()
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("pick", params, socket),
    do: {:noreply, assign(socket, selected: MapSet.new(Map.get(params, "plays", [])))}

  def handle_event("run", _params, socket) do
    keys = MapSet.to_list(socket.assigns.selected)

    {:noreply,
     socket
     |> assign(running: true, error: nil)
     |> start_async(:run, fn -> Together.run(keys) end)}
  end

  def handle_event("base", %{"base" => key}, socket),
    do: {:noreply, assign(socket, base: key, companions: nil)}

  def handle_event("find", _params, %{assigns: %{base: base}} = socket) when is_binary(base) do
    {:noreply,
     socket
     |> assign(finding: true, companion_error: nil)
     |> start_async(:companions, fn -> Together.companions(base) end)}
  end

  def handle_event("find", _params, socket), do: {:noreply, socket}

  def handle_event("add", %{"key" => key}, socket),
    do: {:noreply, update(socket, :selected, &MapSet.put(&1, key))}

  @impl true
  def handle_async(:run, {:ok, {:ok, result}}, socket),
    do: {:noreply, assign(socket, running: false, result: result)}

  def handle_async(:run, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, running: false, error: Client.describe_error(reason))}

  def handle_async(:run, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, running: false, error: "The run didn't finish.")}

  def handle_async(:companions, {:ok, {:ok, rows}}, socket),
    do: {:noreply, assign(socket, finding: false, companions: Enum.take(rows, @shown_companions))}

  def handle_async(:companions, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, finding: false, companion_error: Client.describe_error(reason))}

  def handle_async(:companions, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, finding: false, companion_error: "The search didn't finish.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex max-w-[1040px] flex-col gap-8">
        <header class="flex flex-col gap-1">
          <h1 class="text-[24px] font-semibold tracking-tight">
            <.t {copy("Strategies together")} />
          </h1>
          <p class="m-0 text-[14px] text-muted">
            <.t {copy(
              "Each strategy's backtest replayed on one account at the same time, with your safety rules applied the way the live engine applies them. Plays that win and lose at the same moments add risk; plays that move on their own steady the account."
            )} />
          </p>
        </header>

        <form phx-change="pick" phx-submit="run" class="flex flex-col gap-4">
          <fieldset class="flex flex-col gap-2">
            <legend class="mb-1 text-[15px] font-semibold"><.t {copy("Your strategies")} /></legend>
            <.play_box :for={p <- @choices.yours} play={p} selected={@selected} />
          </fieldset>

          <details class="flex flex-col gap-2">
            <summary class="cursor-pointer text-[15px] font-semibold">
              Tested plays that passed the walk-forward · {length(@choices.tested)}
            </summary>
            <div class="mt-2 flex flex-col gap-2">
              <.play_box :for={p <- @choices.tested} play={p} selected={@selected} />
            </div>
          </details>

          <div class="flex flex-wrap items-center gap-3">
            <button
              type="submit"
              disabled={@running or MapSet.size(@selected) == 0}
              class="min-h-11 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110 disabled:opacity-50"
            >
              {if @running, do: "Running…", else: "Run #{MapSet.size(@selected)} together"}
            </button>
            <span class="text-[13px] text-muted">
              <.t {copy("Up to a minute when 5-minute strategies are in it.")} />
            </span>
          </div>
        </form>

        <p
          :if={@error}
          role="alert"
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@error}
        </p>

        <.results :if={@result} result={@result} limits={@limits} />

        <section class="flex flex-col gap-3 border-t border-neutral pt-6">
          <h2 class="text-[18px] font-semibold tracking-tight"><.t {copy("Find a companion")} /></h2>
          <p class="m-0 text-[14px] text-muted">
            <.t {copy(
              "Pair one strategy with every other play and rank them by how much steadier the pair is than it alone (its Sharpe). The best partners usually move on their own: a different market, style or timeframe."
            )} />
          </p>
          <form phx-change="base" phx-submit="find" class="flex flex-wrap items-center gap-3">
            <select
              name="base"
              aria-label="Strategy to find a companion for"
              class="min-h-11 rounded-field border border-base-300 bg-base-100 px-3 text-[14px]"
            >
              <option
                :for={p <- @choices.yours ++ @choices.tested}
                value={p.key}
                selected={p.key == @base}
              >
                {Together.label(p)}
              </option>
            </select>
            <button
              type="submit"
              disabled={@finding or @base == nil}
              class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] font-medium hover:border-primary disabled:opacity-50"
            >
              {if @finding, do: "Searching…", else: "Find a companion"}
            </button>
            <span class="text-[13px] text-muted">
              <.t {copy("Backtests every play: a minute or two.")} />
            </span>
          </form>
          <p :if={@companion_error} role="alert" class="text-[14px] text-warning">
            {@companion_error}
          </p>
          <.companions :if={@companions} rows={@companions} selected={@selected} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :play, :map, required: true
  attr :selected, :any, required: true

  defp play_box(assigns) do
    ~H"""
    <label class="flex min-h-11 items-center gap-3 text-[14px]">
      <input
        type="checkbox"
        name="plays[]"
        value={@play.key}
        checked={MapSet.member?(@selected, @play.key)}
        class="size-4"
      />
      <span>
        <span class="font-medium">{@play.name}</span>
        <span class="text-muted">
          · {@play.instrument} · {@play.timeframe}{if @play.enabled, do: " · trading"}
        </span>
      </span>
    </label>
    """
  end

  attr :result, :map, required: true
  attr :limits, :map, default: nil

  defp results(assigns) do
    ~H"""
    <section class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <h2 class="text-[18px] font-semibold tracking-tight"><.t {copy("Together")} /></h2>
      <p class="m-0 text-[15px]">{headline(@result)}</p>
      <.account_curve
        with_rules={@result.with_rules}
        without_rules={@result.without_rules}
        from={@result.from}
        to={@result.to}
      />
      <p :if={@result.with_rules} class="m-0 text-[14px]">{rules_words(@result)}</p>
      <p :if={@result.with_rules} class="m-0 text-[14px]">
        {trip_words(@result.with_rules, @limits)}
      </p>

      <div class="overflow-x-auto">
        <table class="w-full min-w-[560px] text-[14px]">
          <caption class="pb-2 text-left text-[13px] text-muted">
            Each alone over the same years, and the trades it got to make together.
          </caption>
          <thead>
            <tr class="text-left text-[13px] text-muted">
              <th class="py-1.5 pr-4 font-normal">Strategy</th>
              <th class="py-1.5 pr-4 text-right font-normal">A year alone</th>
              <th class="py-1.5 pr-4 text-right font-normal">Worst drop</th>
              <th class="py-1.5 pr-4 text-right font-normal">Sharpe</th>
              <th class="py-1.5 text-right font-normal">Trades together</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @result.plays} class="border-t border-neutral">
              <td class="py-1.5 pr-4">{Together.label(p)}</td>
              <td class="py-1.5 pr-4 text-right">{signed_pct(p.alone.annual_return)}</td>
              <td class="py-1.5 pr-4 text-right">{pct(p.alone.max_drawdown)}</td>
              <td class="py-1.5 pr-4 text-right">{num(p.alone.annual_sharpe)}</td>
              <td class="py-1.5 text-right">
                {Map.get((@result.with_rules || @result.without_rules).taken_by_play, p.key, 0)} of {p.alone.taken}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@result.pairs != []} class="flex flex-col gap-1.5">
        <span class="text-[14px] font-medium"><.t {copy("How alike they move, day to day")} /></span>
        <ul class="m-0 flex list-none flex-col gap-1 p-0 text-[14px]">
          <li :for={pair <- @result.pairs}>
            {pair.a} and {pair.b}:
            <span class="font-medium">{Together.alike_words(pair.correlation)}</span>
            <span class="text-muted">({num(pair.correlation)})</span>
          </li>
        </ul>
      </div>

      <p :for={f <- @result.failed} class="m-0 text-[13px] text-warning">
        Couldn't test {f.name}: {f.error}
      </p>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :selected, :any, required: true

  defp companions(assigns) do
    ~H"""
    <p :if={@rows == []} class="m-0 text-[14px] text-muted">
      <.t {copy("No other play shares enough history with it to compare.")} />
    </p>
    <div :if={@rows != []} class="overflow-x-auto">
      <table class="w-full min-w-[640px] text-[14px]">
        <thead>
          <tr class="text-left text-[13px] text-muted">
            <th class="py-1.5 pr-4 font-normal">Partner</th>
            <th class="py-1.5 pr-4 font-normal">Moves</th>
            <th class="py-1.5 pr-4 text-right font-normal">Sharpe: alone → pair</th>
            <th class="py-1.5 pr-4 text-right font-normal">Worst drop: alone → pair</th>
            <th class="py-1.5 font-normal"><span class="sr-only">Add</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows} class="border-t border-neutral">
            <td class="py-1.5 pr-4">
              {Together.label(r.play)}
              <span class="block text-[12px] text-muted">
                its own Sharpe {num(r.alone_sharpe)} · {date(r.from)} – {date(r.to)}
              </span>
            </td>
            <td class="py-1.5 pr-4">{Together.alike_words(r.correlation)}</td>
            <td class={["py-1.5 pr-4 text-right", gain_class(r.sharpe_gain)]}>
              {num(r.base_sharpe)} → {num(r.pair_sharpe)}
            </td>
            <td class="py-1.5 pr-4 text-right">{pct(r.base_drawdown)} → {pct(r.pair_drawdown)}</td>
            <td class="py-1.5">
              <button
                :if={!MapSet.member?(@selected, r.play.key)}
                type="button"
                phx-click="add"
                phx-value-key={r.play.key}
                class="min-h-11 rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary"
              >
                Add
              </button>
              <span :if={MapSet.member?(@selected, r.play.key)} class="text-[13px] text-muted">added</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="mt-2 text-[12px] text-muted">
        Each pair is compared over the years both have history, with your safety rules. A partner still has to
        pass its own tests: pairing doesn't rescue a play with no edge.
      </p>
    </div>
    """
  end

  defp headline(%{with_rules: w, without_rules: wo, plays: plays} = r) do
    o = w || wo
    n = length(plays)

    together =
      "From #{date(r.from)} to #{date(r.to)}, these #{n} on one account made " <>
        "#{signed_pct(o.annual_return)} a year (#{signed_pct(o.total_return)} in all), " <>
        "with a worst drop of #{pct(o.max_drawdown)} and a Sharpe of #{num(o.annual_sharpe)}."

    case Enum.max_by(plays, & &1.alone.annual_sharpe, fn -> nil end) do
      nil ->
        together

      best when n > 1 ->
        verdict =
          if o.annual_sharpe > best.alone.annual_sharpe,
            do: "Together is steadier than the best of them alone",
            else:
              "Together isn't steadier than the best of them alone; they move too much alike, or the rest are weaker"

        "#{together} #{verdict} (#{Together.label(best)}, Sharpe #{num(best.alone.annual_sharpe)})."

      _single ->
        together
    end
  end

  defp rules_words(%{with_rules: w, without_rules: wo}) do
    blocked = w.blocked.risk_budget + w.blocked.group_cap

    let_through =
      "Your safety rules let #{w.taken} trades through and blocked #{blocked}: " <>
        "#{w.blocked.risk_budget} for the risk budget, #{w.blocked.group_cap} for the group limit."

    busy =
      if w.blocked.instrument_busy > 0,
        do:
          " #{w.blocked.instrument_busy} more were skipped because another strategy already held " <>
            "that instrument, as the live engine does.",
        else: ""

    effect =
      " Without the rules: #{signed_pct(wo.annual_return)} a year, worst drop #{pct(wo.max_drawdown)}, " <>
        "Sharpe #{num(wo.annual_sharpe)}."

    let_through <> busy <> effect
  end

  defp trip_words(w, limits) do
    pause =
      case w.pause_trips do
        [] ->
          "The #{limits && limits.drawdown_pause_pct}% drawdown pause would never have tripped."

        trips ->
          "The #{limits && limits.drawdown_pause_pct}% drawdown pause would have tripped #{times(length(trips))} " <>
            "(first #{date(hd(trips))})."
      end

    breaker =
      case w.breaker_trips do
        [] ->
          " The circuit breaker would never have switched a strategy off."

        trips ->
          per =
            trips
            |> Enum.frequencies_by(& &1.name)
            |> Enum.map_join("; ", fn {name, k} -> "#{name} #{times(k)}" end)

          " The circuit breaker would have switched off: #{per}."
      end

    pause <> breaker <> " The replay assumes you pressed resume straight away each time."
  end

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  defp gain_class(gain) when gain > 0.05, do: "text-success"
  defp gain_class(gain) when gain < -0.05, do: "text-error"
  defp gain_class(_gain), do: nil
end
