defmodule OpusWeb.StrategiesLive do
  @moduledoc """
  Strategies, one card per recipe (`Opus.Trading.Strategies.recipes/0`),
  filterable by trading, off and drafts: its rules in plain words, whether
  it's locked (something is trading on it), a small chart of where it
  bought and sold on its first instrument (from the engine's signal
  preview, loaded after the page), and the instruments it runs on. Each
  instrument row has its switch, a status line (trading, held and why,
  suspended, or off), its size and its test results, and links to that
  instrument's page for the full chart and trades.

  Everything comes from Opus's own tables, so the page stands without the
  engine; the live numbers on a trading row need it and are left out when
  it is down.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.SignalChart, only: [signal_sparkline: 1]
  import OpusWeb.StrategyParts

  alias Opus.Auro.Client
  alias Opus.Trading.{AccountPause, RulesEngine, Strategies}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Strategies",
        recipes: [],
        filter: :all,
        ticking: false,
        sparks: %{},
        stats: %{},
        engine_error: nil,
        pause: nil,
        as_of: nil
      )

    {:ok, if(connected?(socket), do: socket |> load() |> load_sparks(), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("filter", %{"to" => to}, socket)
      when to in ~w(all trading off draft),
      do: {:noreply, assign(socket, filter: String.to_existing_atom(to))}

  def handle_event("toggle", %{"id" => id}, socket) do
    case Strategies.toggle(id) do
      {:ok, %{"enabled" => enabled}} ->
        {:noreply,
         socket
         |> put_flash(:info, if(enabled, do: "Strategy enabled.", else: "Strategy disabled."))
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not flip the switch: #{describe(reason)}")}
    end
  end

  def handle_event("resume", _params, socket) do
    AccountPause.clear()
    RulesEngine.recompute()
    {:noreply, socket |> put_flash(:info, "Trading resumed; rules recomputing.") |> load()}
  end

  def handle_event("reset", %{"id" => id}, socket) do
    case Strategies.reset_suspension(id) do
      {:ok, _count} ->
        {:noreply, socket |> put_flash(:info, "Suspension cleared; rules recomputing.") |> load()}

      {:error, :none_open} ->
        {:noreply, socket |> put_flash(:error, "No open suspension to clear.") |> load()}

      {:error, :invalid_id} ->
        {:noreply, put_flash(socket, :error, "Unknown strategy.")}
    end
  end

  defp load(socket) do
    {stats, engine_error} =
      case Strategies.stats() do
        {:ok, stats} -> {stats, nil}
        {:error, reason} -> {%{}, describe(reason)}
      end

    recipes = Strategies.recipes()
    tick? = connected?(socket) and busy?(recipes) and not socket.assigns.ticking
    if tick?, do: Process.send_after(self(), :tick, 5_000)

    assign(socket,
      ticking: socket.assigns.ticking or tick?,
      recipes: recipes,
      stats: stats,
      engine_error: engine_error,
      pause: AccountPause.open(),
      as_of: DateTime.utc_now()
    )
  end

  # One engine preview per assigned recipe, on its first instrument, after
  # the page is up; a card without one just shows no chart.
  defp load_sparks(socket) do
    for %{assignments: [first | _]} = recipe <- socket.assigns.recipes, reduce: socket do
      socket ->
        start_async(socket, {:spark, recipe.id}, fn ->
          {first.instrument,
           Strategies.preview(
             recipe.definition,
             first.instrument,
             recipe.granularity,
             first.sizing_params
           )}
        end)
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, socket |> assign(ticking: false) |> load()}

  @impl true
  def handle_async({:spark, id}, {:ok, {instrument, {:ok, chart}}}, socket),
    do: {:noreply, update(socket, :sparks, &Map.put(&1, id, {instrument, chart}))}

  def handle_async({:spark, _id}, _result, socket), do: {:noreply, socket}

  defp describe(reason), do: Client.describe_error(reason)

  defp shown(recipes, :all), do: recipes
  defp shown(recipes, status), do: Enum.filter(recipes, &(&1.status == status))

  defp count(recipes, status), do: Enum.count(recipes, &(&1.status == status))

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        rows: Enum.flat_map(assigns.recipes, & &1.assignments),
        shown: shown(assigns.recipes, assigns.filter)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="flex flex-col gap-1">
            <h1 class="text-[24px] font-semibold tracking-tight">
              <.t {copy("Strategies")} />
            </h1>
            <span class="text-[13px] text-muted">
              {length(@recipes)} recipes · {Enum.count(@rows, & &1.enabled)} of {length(@rows)}
              <.t {copy("enabled")} />
              <span :if={@as_of}>· updated {clock(@as_of)}</span>
              <button
                type="button"
                phx-click="refresh"
                class="ml-1 font-medium text-primary hover:brightness-110"
              >
                Refresh
              </button>
            </span>
          </div>
          <.link
            navigate={~p"/strategies/new"}
            class="inline-flex min-h-11 items-center gap-2 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110"
          >
            <.icon name="hero-plus-mini" class="size-4" />
            <.t {copy("New strategy")} />
          </.link>
        </header>

        <section
          :if={@pause}
          role="alert"
          class="flex flex-wrap items-center justify-between gap-4 rounded-box border border-error/50 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-col gap-1">
            <span class="text-[15px] font-semibold text-error">
              <.t {copy("Trading is paused: the account fell %{down} from its peak",
                down: pct(AccountPause.drawdown(@pause.peak_nav, @pause.nav))
              )} />
            </span>
            <span class="text-[13px] text-muted">
              NAV {money(@pause.nav)} against a peak of {money(@pause.peak_nav)}; the limit is {@pause.limit_pct}%.
              No strategy opens a trade until you resume. Open trades keep their stops and exits.
            </span>
          </div>
          <button
            type="button"
            phx-click="resume"
            class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] font-medium hover:border-primary"
          >
            <.t {copy("Resume trading")} />
          </button>
        </section>

        <p
          :if={@engine_error}
          role="alert"
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@engine_error} Showing what Opus knows; live numbers and charts need the engine.
        </p>

        <div role="group" aria-label="Show" class="flex flex-wrap gap-2">
          <.filter_pill filter={@filter} to={:all} count={length(@recipes)} label={copy("All")} />
          <.filter_pill
            filter={@filter}
            to={:trading}
            count={count(@recipes, :trading)}
            label={copy("Trading")}
          />
          <.filter_pill
            filter={@filter}
            to={:off}
            count={count(@recipes, :off)}
            label={copy("Off")}
          />
          <.filter_pill
            filter={@filter}
            to={:draft}
            count={count(@recipes, :draft)}
            label={copy("Drafts")}
          />
        </div>

        <p :if={@as_of && @shown == []} class="text-[13px] text-muted">
          <.t {copy("Nothing here.")} />
        </p>

        <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,540px),1fr))] gap-5">
          <article
            :for={recipe <- @shown}
            id={"recipe-#{recipe.id}"}
            class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-5"
          >
            <header class="flex flex-wrap items-start justify-between gap-3">
              <div class="flex min-w-0 flex-col gap-0.5">
                <h2 class="text-[18px] font-semibold tracking-tight">
                  <.link
                    navigate={recipe_path(recipe)}
                    class="hover:text-primary"
                  >
                    {recipe.name}
                  </.link>
                </h2>
                <span class="text-[13px] text-muted">
                  {recipe.timeframe} · built {Calendar.strftime(recipe.created_at, "%b %-d")}
                </span>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <.lock_badge locked_by={recipe.locked_by} />
              </div>
            </header>

            <p :if={recipe.notes} class="m-0 text-[14px]">{recipe.notes}</p>

            <dl class="grid grid-cols-1 gap-x-5 gap-y-1.5 text-[14px] sm:grid-cols-[9rem_minmax(0,1fr)]">
              <%= for {label, text} <- recipe.rules do %>
                <dt class="text-muted">{label}</dt>
                <dd class="m-0">{text}</dd>
              <% end %>
            </dl>

            <figure :if={@sparks[recipe.id]} class="m-0 flex flex-col gap-1">
              <.signal_sparkline
                chart={elem(@sparks[recipe.id], 1)}
                label={"Where it bought and sold on #{elem(@sparks[recipe.id], 0)}"}
              />
              <figcaption class="flex flex-wrap gap-x-4 text-[12px] text-muted">
                <span><span aria-hidden="true" class="text-info">▲</span> <.t {copy("buy")} /></span>
                <span><span aria-hidden="true" class="text-warning">▼</span>
                <.t {copy("sell")} /></span>
                <span>last 120 bars on {elem(@sparks[recipe.id], 0)}, from the rules</span>
              </figcaption>
            </figure>

            <p
              :if={recipe.assignments == [] and recipe.runs == []}
              class="m-0 text-[14px] text-muted"
            >
              <.t {copy("Not running on any instrument yet, and not tested. Open it to test it on one.")} />
            </p>

            <div :if={recipe.runs != []} class="flex flex-col gap-1">
              <span class="text-[13px] text-muted">
                <.t {copy("Also tested on")} />
              </span>
              <ul class="m-0 flex list-none flex-wrap gap-x-5 gap-y-1 p-0">
                <li :for={run <- recipe.runs} class="flex items-baseline gap-2 text-[14px]">
                  <.link navigate={tests_path(recipe)} class="font-medium hover:text-primary">
                    {run.instrument}
                  </.link>
                  <.test_badge results={run.stages} />
                </li>
              </ul>
            </div>

            <ul
              :if={recipe.assignments != []}
              class="m-0 flex list-none flex-col border-t border-neutral p-0"
            >
              <li
                :for={row <- recipe.assignments}
                id={"strategy-#{row.id}"}
                class="flex flex-col gap-3 border-b border-neutral py-3.5 last:border-b-0"
              >
                <div class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-5 gap-y-2 sm:grid-cols-[minmax(0,4fr)_minmax(0,6fr)_auto]">
                  <div class="flex min-w-0 flex-col gap-0.5">
                    <.link
                      navigate={~p"/strategies/#{row.id}"}
                      class="truncate text-[15px] font-medium hover:text-primary"
                    >
                      {row.instrument}
                    </.link>
                    <span class="text-[13px] text-muted">{row.sizing}</span>
                  </div>
                  <div class="order-last col-span-2 flex min-w-0 flex-col gap-0.5 sm:order-none sm:col-span-1">
                    <.status row={row} stats={@stats[row.id]} />
                  </div>
                  <.switch row={row} />
                </div>
                <.link navigate={~p"/strategies/#{row.id}" <> "#tests"} class="self-start">
                  <.test_badge results={row.results} />
                </.link>
              </li>
            </ul>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :filter, :atom, required: true
  attr :to, :atom, required: true
  attr :count, :integer, required: true
  attr :label, :map, required: true, doc: "copy/1"

  defp filter_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-to={@to}
      aria-pressed={to_string(@filter == @to)}
      class={[
        "min-h-11 rounded-full border px-4 text-[14px]",
        if(@filter == @to,
          do: "border-primary bg-primary/10 font-medium",
          else: "border-base-300 text-muted hover:text-base-content"
        )
      ]}
    >
      <.t {@label} /> · {@count}
    </button>
    """
  end

  # A drafted recipe has no instrument page yet; it opens in the builder.
  defp recipe_path(%{assignments: [first | _]}), do: ~p"/strategies/#{first.id}"
  defp recipe_path(recipe), do: ~p"/strategies/recipes/#{recipe.id}/edit"

  # Where a recipe's full test results are listed.
  defp tests_path(recipe), do: recipe_path(recipe) <> "#tests"

  # Tests take a while; while any is waiting or running, look again shortly.
  defp busy?(recipes) do
    Enum.any?(recipes, fn recipe ->
      stage_sets =
        Enum.map(recipe.runs, & &1.stages) ++ Enum.map(recipe.assignments, & &1.results)

      Enum.any?(stage_sets, fn stages ->
        Enum.any?(
          [:backtest, :walk_forward, :monte_carlo, :holdout],
          &(stages[&1].status in [:pending, :running])
        )
      end)
    end)
  end

  attr :row, :map, required: true
  attr :stats, :map, default: nil

  defp status(%{row: %{suspension: suspension}} = assigns) when not is_nil(suspension) do
    ~H"""
    <span class="text-[14px] font-medium text-error"><.t {copy("Suspended")} /></span>
    <span class="text-[13px] text-muted">
      {@row.suspension.trigger_detail} ·
      <button
        type="button"
        phx-click="reset"
        phx-value-id={@row.id}
        class="font-medium text-primary hover:brightness-110"
      >
        <.t {copy("Reset")} />
      </button>
    </span>
    """
  end

  defp status(%{row: %{enabled: false}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-muted"><.t {copy("Off")} /></span>
    """
  end

  defp status(%{row: %{rule: nil}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium"><.t {copy("On, no decision yet")} /></span>
    """
  end

  defp status(%{row: %{rule: %{enabled: true}}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-success">
      <.t {copy("Trading")} /><span
        :if={@row.open_trades > 0}
        class="font-normal text-base-content"
      > · {@row.open_trades} open</span>
    </span>
    <span class="text-[13px] text-muted">
      <.t {live_line(@stats, @row)} />
    </span>
    """
  end

  defp status(assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-warning"><.t {copy("Held")} /></span>
    <span class="truncate text-[13px] text-muted" title={@row.rule.reason}>{@row.rule.reason}</span>
    """
  end

  attr :row, :map, required: true

  defp switch(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle"
      phx-value-id={@row.id}
      disabled={@row.suspension != nil}
      aria-pressed={to_string(@row.enabled)}
      aria-label={"#{if @row.enabled, do: "Disable", else: "Enable"} #{@row.name}"}
      class={[
        "inline-flex min-h-11 items-center gap-2 rounded-field border border-base-300 bg-base-200 px-3 text-[13px] font-medium disabled:cursor-not-allowed disabled:opacity-50",
        if(@row.enabled, do: "text-success", else: "text-muted")
      ]}
    >
      <span
        aria-hidden="true"
        class={["size-2 rounded-full", if(@row.enabled, do: "bg-success", else: "bg-base-300")]}
      />
      <.t :if={@row.enabled} {copy("Enabled")} />
      <.t :if={!@row.enabled} {copy("Disabled")} />
    </button>
    """
  end

  defp live_line(%{live: %{"num_trades" => n} = live}, _row) when is_integer(n) and n > 0 do
    copy_n(
      "%{count} live trade · %{win} win · %{return}",
      "%{count} live trades · %{win} win · %{return}",
      n,
      win: pct(live["win_rate"]),
      return: signed_pct(live["total_return"])
    )
  end

  defp live_line(_stats, %{last_signal: %{action: action, at: at}}) do
    copy("last signal %{action} · %{at}",
      action: String.replace(action, "_", " "),
      at: stamp(at)
    )
  end

  defp live_line(_stats, _row), do: copy("no trades yet")
end
