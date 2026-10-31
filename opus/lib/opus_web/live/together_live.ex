defmodule OpusWeb.TogetherLive do
  @moduledoc """
  Strategies backtested together on one account (`Opus.Trading.Together`),
  as building a team in three steps:

  1. **Your team**: a card per strategy (your switched-on ones to start),
     with what it does alone once run; add any strategy or tested play
     from a searchable picker, take one off with its ×.
  2. **How the account would have done**: the verdict in plain words,
     return, worst drop and steadiness, the account's chart, who carries
     the team, who moves with who, and what the safety rules did.
  3. **Find a teammate**: why one helps, then every other play paired
     with the one you pick, best first, each with an Add to team button.

  Every play says where it stands (on and trading, switched off, ready,
  failed, still testing, or tested before the current rules) with its one
  next step towards live: open it to switch it on, add it to live switched
  off, or re-test it by today's rules. Switching on stays on the strategy's
  own page. Plays tested before the current rules are hidden until "Show
  old tests".

  "Show the numbers" adds the Sharpe ratios, correlations and the
  with/without-rules table. Both runs backtest in the engine, so they run
  after the click and say so while they do.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.ResultCharts, only: [account_curve: 1]
  import OpusWeb.SafetyLive, only: [numbers_switch: 1]

  import OpusWeb.StrategyParts,
    only: [missed_words: 1, resume: 1, resume_button: 1, stage_name: 1]

  alias Opus.Auro.Client
  alias Opus.Trading.{AccountLimits, Together}

  @shown_companions 10

  # How much higher a Sharpe must be to call something steadier.
  @steadier 0.08

  @impl true
  def mount(_params, _session, socket) do
    socket = load_choices(socket)
    selected = socket.assigns.choices.yours |> Enum.filter(& &1.enabled) |> Enum.map(& &1.key)

    socket =
      assign(socket,
        page_title: "Together",
        selected: selected,
        show_old: false,
        picking: false,
        query: "",
        numbers: false,
        running: false,
        result: nil,
        error: nil,
        base: List.first(selected),
        finding: false,
        companions: nil,
        companion_error: nil,
        limits: AccountLimits.get()
      )

    {:ok, socket}
  end

  # The choices, fresh. A team member whose key changed (promoted to live,
  # or re-tested as a new run) stays on the team under its new key.
  defp load_choices(socket) do
    choices = Together.choices()
    plays = choices.yours ++ choices.tested
    by_key = Map.new(plays, &{&1.key, &1})
    before = socket.assigns[:by_key] || %{}

    selected =
      (socket.assigns[:selected] || [])
      |> Enum.flat_map(fn key ->
        cond do
          by_key[key] ->
            [key]

          was = before[key] ->
            plays |> Enum.filter(&Together.same?(&1, was)) |> Enum.map(& &1.key)

          true ->
            []
        end
      end)
      |> Enum.uniq()

    assign(socket, choices: choices, by_key: by_key, selected: selected)
  end

  @impl true
  def handle_event("numbers", _params, socket), do: {:noreply, update(socket, :numbers, &(!&1))}

  def handle_event("picker", _params, socket),
    do: {:noreply, assign(socket, picking: !socket.assigns.picking, query: "")}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def handle_event("old", _params, socket),
    do: {:noreply, assign(socket, show_old: !socket.assigns.show_old, companions: nil)}

  def handle_event("promote", %{"key" => key}, socket) do
    name = Together.label(socket.assigns.by_key[key])

    socket =
      case Together.promote(key) do
        {:ok, _promoted} ->
          put_flash(
            socket,
            :info,
            "Added #{name} to live, switched off. Open it from the team to switch it on."
          )

        {:error, :not_ready} ->
          put_flash(socket, :error, "#{name} hasn't passed every test, so it can't go live.")

        {:error, reason} ->
          put_flash(
            socket,
            :error,
            "Couldn't add #{name} to live: #{Client.describe_error(reason)}"
          )
      end

    {:noreply, load_choices(socket)}
  end

  def handle_event("retest", %{"key" => key}, socket) do
    name = Together.label(socket.assigns.by_key[key])

    socket =
      case Together.retest(key) do
        {:ok, _config} ->
          socket
          |> put_flash(
            :info,
            "Re-testing #{name} with today's rules. Every test runs again; it shows here as still testing until it's done."
          )

        {:error, :not_old} ->
          put_flash(socket, :error, "#{name} was already tested by today's rules.")

        {:error, {kind, _names} = why} when kind in [:no_broker, :no_dividends] ->
          put_flash(socket, :error, Opus.Instruments.untestable_words(why))

        {:error, _reason} ->
          put_flash(socket, :error, "Couldn't start the tests for #{name}.")
      end

    {:noreply, load_choices(socket)}
  end

  def handle_event("resume_stage", params, socket) do
    {kind, words} = resume(params)
    {:noreply, socket |> put_flash(kind, words) |> load_choices()}
  end

  def handle_event("add", %{"key" => key}, socket),
    do: {:noreply, update(socket, :selected, &if(key in &1, do: &1, else: &1 ++ [key]))}

  def handle_event("remove", %{"key" => key}, socket),
    do: {:noreply, update(socket, :selected, &List.delete(&1, key))}

  def handle_event("toggle_mate", %{"key" => key}, socket) do
    update = if key in socket.assigns.selected, do: &List.delete(&1, key), else: &(&1 ++ [key])
    {:noreply, update(socket, :selected, update)}
  end

  def handle_event("run", _params, %{assigns: %{selected: [_ | _] = keys}} = socket) do
    {:noreply,
     socket
     |> assign(running: true, error: nil, picking: false)
     |> start_async(:run, fn -> Together.run(keys) end)}
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  def handle_event("base", %{"base" => key}, socket),
    do: {:noreply, assign(socket, base: key, companions: nil)}

  def handle_event("find", _params, %{assigns: %{base: base}} = socket) when is_binary(base) do
    with_old = socket.assigns.show_old

    {:noreply,
     socket
     |> assign(finding: true, companion_error: nil)
     |> start_async(:companions, fn -> Together.companions(base, with_old) end)}
  end

  def handle_event("find", _params, socket), do: {:noreply, socket}

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
    assigns =
      assign(assigns,
        team: Enum.flat_map(assigns.selected, &List.wrap(assigns.by_key[&1])),
        others:
          Enum.reject(
            assigns.choices.yours ++ visible(assigns.choices.tested, assigns.show_old),
            &(&1.key in assigns.selected)
          ),
        old_count: Enum.count(assigns.choices.tested, & &1.old),
        alone: alone_by_key(assigns.result)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex max-w-[1120px] flex-col gap-7">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="flex max-w-[680px] flex-col gap-1.5">
            <h1 class="text-[32px] font-bold tracking-tight">
              <.t {copy("Strategies together")} />
            </h1>
            <p class="m-0 text-[16px] text-muted">
              <.t {copy(
                "Your strategies don't trade alone: they share one account. See how they'd have done as a team, and find a teammate that makes the account steadier."
              )} />
            </p>
          </div>
          <.numbers_switch on={@numbers} />
        </header>

        <section
          aria-label="How this works"
          class="grid grid-cols-1 gap-5 rounded-box border border-base-300 bg-base-200 px-6 py-5 md:grid-cols-3"
        >
          <.how_step n="1" active={@result == nil} title="Pick your team">
            Start with what's trading. Add any tested play to see what it would change.
          </.how_step>
          <.how_step n="2" active={@result != nil and @companions == nil} title="See the account">
            Their backtests replayed on one account, with your safety rules, as live.
          </.how_step>
          <.how_step n="3" active={@companions != nil} title="Find a teammate">
            The plays that lose on different days than yours steady the account most.
          </.how_step>
        </section>

        <section aria-labelledby="team-h" class="flex flex-col gap-3.5">
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h2 id="team-h" class="text-[22px] font-bold">
              <.t {copy("1 · Your team")} />
            </h2>
            <span class="text-[14px] text-muted">{team_count(@team)}</span>
          </div>
          <p class="m-0 max-w-[760px] text-[14px] text-muted">
            <.t {copy(
              "Strategies that are switched on already trade as one team on your account. To add a teammate for real: it has to pass every test, then you switch it on."
            )} />
          </p>

          <div class="grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-3">
            <div
              :for={p <- @team}
              id={"team-#{p.key}"}
              class="flex flex-col gap-2.5 rounded-box border border-base-300 bg-base-200 p-4"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="font-semibold">{p.name}</div>
                  <div class="text-[13px] text-muted">
                    {p.instrument} · {p.timeframe}<span :if={p[:variant]}> · {p.variant}</span>
                  </div>
                </div>
                <button
                  type="button"
                  phx-click="remove"
                  phx-value-key={p.key}
                  aria-label={"Take #{p.name} on #{p.instrument} off the team"}
                  class="-mr-2.5 -mt-2.5 min-h-11 min-w-11 text-[20px] text-muted hover:text-base-content"
                >
                  ×
                </button>
              </div>
              <%= if a = @alone[p.key] do %>
                <span class={[
                  "self-start rounded-full px-2.5 py-1 text-[13px] font-medium",
                  tag_class(a.tag)
                ]}>
                  {tag_words(a.tag)}
                </span>
                <span class="text-[13px] text-muted">
                  Alone: {signed_pct(a.annual_return)} a year, worst drop {pct(a.max_drawdown)}
                </span>
                <span :if={@numbers} class="text-[12px] tabular-nums text-muted">
                  Sharpe {num(a.annual_sharpe)} · {a.taken} trades alone, {a.together} together
                </span>
              <% else %>
                <span class="text-[13px] text-muted">Run the team to see what it does.</span>
              <% end %>
              <.play_status play={p} />
              <.next_step play={p} />
            </div>

            <button
              type="button"
              phx-click="picker"
              aria-expanded={to_string(@picking)}
              class="flex min-h-[150px] flex-col items-center justify-center gap-1.5 rounded-box border border-dashed border-base-300 bg-base-200 p-4 font-semibold text-primary hover:border-primary"
            >
              <span class="text-[26px] leading-none">{if @picking, do: "−", else: "+"}</span>
              {if @picking, do: "Done adding", else: "Add a strategy"}
              <span class="text-[13px] font-normal text-muted">
                yours, or one of {length(visible(@choices.tested, @show_old))} tested plays
              </span>
            </button>
          </div>

          <.picker
            :if={@picking}
            choices={@choices}
            selected={@selected}
            query={@query}
            show_old={@show_old}
            old_count={@old_count}
          />

          <div class="flex flex-wrap items-center gap-3.5">
            <button
              type="button"
              phx-click="run"
              disabled={@running or @team == []}
              class="min-h-12 rounded-field bg-primary px-6 text-[16px] font-semibold text-primary-content hover:brightness-110 disabled:opacity-50"
            >
              {if @running, do: "Running…", else: "See how they do together"}
            </button>
            <span class="text-[14px] text-muted">
              {if @team == [],
                do: "Add at least one strategy.",
                else: "A few seconds; up to a minute with many 5-minute strategies."}
            </span>
          </div>
          <p
            :if={@error}
            role="alert"
            class="m-0 rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-[14px]"
          >
            {@error}
          </p>
        </section>

        <.results :if={@result} result={@result} limits={@limits} numbers={@numbers} alone={@alone} />

        <section aria-labelledby="mate-h" class="flex flex-col gap-3.5">
          <h2 id="mate-h" class="text-[22px] font-bold">
            <.t {copy("3 · Find a teammate")} />
          </h2>
          <div class="grid grid-cols-1 items-center gap-6 rounded-box border border-base-300 bg-base-200 px-6 py-5 md:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
            <div class="flex flex-col gap-2">
              <span class="font-semibold"><.t {copy("Why a teammate helps")} /></span>
              <p class="m-0 text-[14px] text-muted">
                <.t {copy(
                  "Two plays that lose on the same days are one bigger bet. Two that lose on different days cover for each other: the account's bad days get smaller while the good ones add up. Pick a strategy, and Auro tries every other play next to it and ranks the ones that make the pair steadiest."
                )} />
              </p>
            </div>
            <svg
              role="img"
              aria-label="Two lines that rise and fall at different times combine into a smoother line"
              viewBox="0 0 360 120"
              class="h-[120px] w-full"
            >
              <polyline
                fill="none"
                stroke="var(--color-info)"
                stroke-width="2"
                points="10,80 50,50 90,85 130,45 170,80 210,40 250,75 290,35 340,60"
              />
              <polyline
                fill="none"
                stroke="var(--color-warning)"
                stroke-width="2"
                points="10,50 50,85 90,50 130,85 170,48 210,82 250,45 290,78 340,42"
              />
              <polyline
                fill="none"
                stroke="var(--color-primary)"
                stroke-width="3"
                points="10,65 50,68 90,66 130,62 170,62 210,58 250,58 290,54 340,50"
              />
              <text x="10" y="112" fill="var(--color-neutral-content)" font-size="11">
                two plays that take turns → a smoother account
              </text>
            </svg>
          </div>

          <form
            id="partner-form"
            phx-change="base"
            phx-submit="find"
            class="flex flex-wrap items-center gap-2.5"
          >
            <label for="mate-base" class="font-semibold">Find a teammate for</label>
            <select
              id="mate-base"
              name="base"
              class="min-h-11 rounded-field border border-primary bg-base-200 px-3 text-[15px]"
            >
              <optgroup label="Your team">
                <option :for={p <- @team} value={p.key} selected={p.key == @base}>
                  {Together.label(p)}
                </option>
              </optgroup>
              <optgroup label="Everything else">
                <option
                  :for={p <- @others}
                  value={p.key}
                  selected={p.key == @base}
                >
                  {Together.label(p)}
                </option>
              </optgroup>
            </select>
            <button
              type="submit"
              disabled={@finding or @base == nil}
              class="min-h-11 rounded-field bg-primary px-4 text-[15px] font-semibold text-primary-content hover:brightness-110 disabled:opacity-50"
            >
              {if @finding,
                do: "Searching…",
                else: "Search #{length(@team) + length(@others) - 1} plays"}
            </button>
            <span class="text-[14px] text-muted">about a minute</span>
          </form>
          <p :if={@companion_error} role="alert" class="m-0 text-[14px] text-warning">
            {@companion_error}
          </p>

          <.old_toggle :if={!@picking} count={@old_count} shown={@show_old} />

          <.mates :if={@companions} rows={@companions} selected={@selected} numbers={@numbers} />

          <p class="m-0 text-[13px] text-muted">
            Each pair is compared over the years both have, with your safety rules. A teammate still has to pass its own
            tests first: pairing never rescues a play with no edge.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :n, :string, required: true
  attr :title, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp how_step(assigns) do
    ~H"""
    <div class="flex items-start gap-3.5">
      <span class={[
        "flex size-8 flex-none items-center justify-center rounded-full font-bold",
        if(@active, do: "bg-primary text-primary-content", else: "bg-base-300")
      ]}>
        {@n}
      </span>
      <div>
        <div class="font-semibold">{@title}</div>
        <div class="text-[14px] text-muted">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  attr :choices, :map, required: true
  attr :selected, :list, required: true
  attr :query, :string, required: true
  attr :show_old, :boolean, required: true
  attr :old_count, :integer, required: true

  defp picker(assigns) do
    pick = fn plays ->
      Enum.filter(plays, &(&1.key not in assigns.selected and matches?(&1, assigns.query)))
    end

    assigns =
      assign(assigns,
        yours: pick.(assigns.choices.yours),
        tested: pick.(visible(assigns.choices.tested, assigns.show_old))
      )

    ~H"""
    <div class="flex flex-col gap-3 rounded-box border border-primary bg-base-200 px-5 py-4">
      <form id="picker-search" phx-change="search" onsubmit="return false">
        <label class="flex flex-col gap-1 text-[14px]">
          <span class="font-semibold">Add a strategy</span>
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Search by name or market, e.g. gold, EUR, trend"
            phx-debounce="200"
            class="min-h-11 rounded-field border border-base-300 bg-base-100 px-3"
          />
        </label>
      </form>
      <.picker_group title="Your strategies" plays={@yours} />
      <.picker_group title="Tested plays that passed the walk-forward" plays={@tested} />
      <p :if={@yours == [] and @tested == []} class="m-0 text-[14px] text-muted">Nothing matches.</p>
      <.old_toggle count={@old_count} shown={@show_old} />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :plays, :list, required: true

  defp picker_group(assigns) do
    ~H"""
    <div :if={@plays != []} class="flex flex-col">
      <span class="pb-1 text-[13px] text-muted">{@title}</span>
      <ul class="m-0 max-h-[320px] list-none overflow-y-auto p-0">
        <li
          :for={p <- @plays}
          class="flex items-center justify-between gap-3 border-t border-neutral py-1.5"
        >
          <span class="flex min-w-0 flex-col text-[14px]">
            <span class="truncate">
              <span class="font-medium">{p.name}</span>
              <span class="text-muted">
                · {p.instrument} · {p.timeframe}<span :if={p.variant}> · {p.variant}</span>
              </span>
            </span>
            <span class={["text-[13px]", status_class(p.status)]}>{status_words(p.status)}</span>
          </span>
          <button
            type="button"
            phx-click="add"
            phx-value-key={p.key}
            class="min-h-11 flex-none rounded-field border border-base-300 px-3 text-[13px] font-semibold hover:border-primary"
          >
            Add
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :limits, :map, default: nil
  attr :numbers, :boolean, required: true
  attr :alone, :map, required: true

  defp results(assigns) do
    o = assigns.result.with_rules || assigns.result.without_rules

    assigns =
      assign(assigns,
        o: o,
        steady: steadiness(o.annual_sharpe),
        carry: carry(assigns.result.plays)
      )

    ~H"""
    <section aria-labelledby="result-h" class="flex flex-col gap-4">
      <h2 id="result-h" class="text-[22px] font-bold">
        <.t {copy("2 · How the account would have done")} />
      </h2>

      <div class="flex flex-col gap-2.5 rounded-box border border-primary bg-base-200 px-6 py-5">
        <span class="self-start rounded-full bg-primary/15 px-2.5 py-1 text-[13px] font-medium text-primary">
          The short version
        </span>
        <p class="m-0 text-[22px] font-medium leading-snug">{headline(@result, @o)}</p>
        <p :if={length(@result.plays) > 1} class="m-0 text-muted">{team_words(@result, @o)}</p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 p-4">
          <span class="text-[13px] text-muted">Return</span>
          <span class={[
            "text-[30px] font-bold",
            if(@o.annual_return >= 0, do: "text-primary", else: "text-error")
          ]}>
            {signed_pct(@o.annual_return)}<span class="text-[16px] font-medium text-muted"> a year</span>
          </span>
          <span class="text-[13px] text-muted">
            {signed_pct(@o.total_return, 0)} from {date(@result.from)} to {date(@result.to)}
          </span>
        </div>
        <div class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 p-4">
          <span class="text-[13px] text-muted">Worst drop</span>
          <span class="text-[30px] font-bold">{pct(@o.max_drawdown)}</span>
          <div :if={@limits} class="h-1.5 overflow-hidden rounded-full bg-neutral">
            <div
              class={[
                "h-full",
                if(@o.max_drawdown >= @limits.drawdown_pause_pct / 100 * 0.8,
                  do: "bg-warning",
                  else: "bg-success"
                )
              ]}
              style={"width: #{min(@o.max_drawdown / (@limits.drawdown_pause_pct / 100), 1) * 100}%"}
            />
          </div>
          <span class="text-[13px] text-muted">{pause_words(@o, @limits)}</span>
        </div>
        <div class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 p-4">
          <span class="text-[13px] text-muted">Steadiness</span>
          <span class="text-[30px] font-bold">{elem(@steady, 0)}</span>
          <div class="flex gap-1" aria-hidden="true">
            <span
              :for={seg <- 1..4}
              class={[
                "h-1.5 flex-1 rounded-sm",
                if(seg <= elem(@steady, 1), do: "bg-primary", else: "bg-neutral")
              ]}
            />
          </div>
          <span class="text-[13px] text-muted">
            {if @numbers,
              do:
                "Sharpe #{num(@o.annual_sharpe)} (yearly). Above 1.5 in a backtest usually means too good to be true.",
              else: elem(@steady, 2)}
          </span>
        </div>
      </div>

      <div class="flex flex-col gap-2.5 rounded-box border border-base-300 bg-base-200 px-6 py-5">
        <span class="font-semibold">The account over time</span>
        <.account_curve
          with_rules={@result.with_rules}
          without_rules={@result.without_rules}
          from={@result.from}
          to={@result.to}
        />
      </div>

      <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,340px),1fr))] gap-3">
        <div class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-6 py-5">
          <span class="font-semibold">Who carries the team</span>
          <span class="text-[13px] text-muted">What each would make a year on its own, same years</span>
          <div :for={c <- @carry} class="flex flex-col gap-1">
            <div class="flex justify-between gap-3 text-[14px]">
              <span class="min-w-0 truncate">{c.name}</span>
              <span class="tabular-nums">{signed_pct(c.annual_return)}</span>
            </div>
            <div class="h-2 overflow-hidden rounded-full bg-neutral">
              <div
                class={["h-full", if(c.annual_return >= 0, do: "bg-primary", else: "bg-error")]}
                style={"width: #{c.width}%"}
              />
            </div>
          </div>
        </div>

        <div
          :if={@result.pairs != []}
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-6 py-5"
        >
          <span class="font-semibold">Who moves with who</span>
          <span class="text-[13px] text-muted">
            Do they win and lose on the same days? Same days means one bigger bet, not two.
          </span>
          <div
            :for={pair <- @result.pairs}
            class="flex items-center justify-between gap-2.5 border-t border-neutral py-1.5 text-[14px]"
          >
            <span class="min-w-0">{short(pair.a)} <span class="text-muted">and</span> {short(pair.b)}</span>
            <span class={[
              "flex-none rounded-full px-2.5 py-1 text-[13px] font-medium",
              alike_class(pair.correlation)
            ]}>
              {Together.alike_words(pair.correlation)}{if @numbers, do: " · #{num(pair.correlation)}"}
            </span>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-2 rounded-box border border-base-300 bg-base-200 px-6 py-5">
        <span class="font-semibold">What your safety rules did</span>
        <ul class="m-0 flex flex-col gap-1.5 pl-5">
          <li :for={line <- rules_lines(@result, @limits)}>{line}</li>
        </ul>
        <div :if={@numbers and @result.with_rules} class="mt-1.5 overflow-x-auto">
          <table class="w-full min-w-[560px] text-[13px] tabular-nums">
            <thead>
              <tr class="text-left text-muted">
                <th class="px-2 py-1.5 font-normal">Run</th>
                <th class="px-2 py-1.5 text-right font-normal">A year</th>
                <th class="px-2 py-1.5 text-right font-normal">Worst drop</th>
                <th class="px-2 py-1.5 text-right font-normal">Sharpe</th>
                <th class="px-2 py-1.5 text-right font-normal">Taken</th>
                <th class="px-2 py-1.5 text-right font-normal">Blocked (budget / group)</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={
                  {label, row} <- [
                    {"With your rules", @result.with_rules},
                    {"Without them", @result.without_rules}
                  ]
                }
                class="border-t border-neutral"
              >
                <td class="px-2 py-1.5">{label}</td>
                <td class="px-2 py-1.5 text-right">{signed_pct(row.annual_return, 2)}</td>
                <td class="px-2 py-1.5 text-right">{pct(row.max_drawdown, 2)}</td>
                <td class="px-2 py-1.5 text-right">{num(row.annual_sharpe)}</td>
                <td class="px-2 py-1.5 text-right">{row.taken}</td>
                <td class="px-2 py-1.5 text-right">
                  {row.blocked.risk_budget} / {row.blocked.group_cap}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p :for={f <- @result.failed} class="m-0 text-[13px] text-warning">
        Couldn't test {f.name}: {f.error}
      </p>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :selected, :list, required: true
  attr :numbers, :boolean, required: true

  defp mates(assigns) do
    ~H"""
    <p :if={@rows == []} class="m-0 text-[14px] text-muted">
      <.t {copy("No other play shares enough history with it to compare.")} />
    </p>
    <ol :if={@rows != []} class="m-0 flex list-none flex-col gap-2.5 p-0">
      <li
        :for={{r, i} <- Enum.with_index(@rows, 1)}
        class="grid grid-cols-[auto_minmax(0,1fr)] items-center gap-x-4 gap-y-3 rounded-box border border-base-300 bg-base-200 px-5 py-4 sm:grid-cols-[auto_minmax(0,1fr)_auto]"
      >
        <span class="flex size-9 items-center justify-center rounded-full bg-neutral font-bold">{i}</span>
        <div class="flex min-w-0 flex-col gap-1.5">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold">{Together.label(r.play)}</span>
            <span class={[
              "rounded-full px-2.5 py-1 text-[13px] font-medium",
              alike_class(r.correlation)
            ]}>
              {mate_alike(r.correlation)}
            </span>
          </div>
          <span class="text-[14px]">{mate_words(r)}</span>
          <.play_status play={r.play} />
          <span :if={@numbers} class="text-[12px] tabular-nums text-muted">
            Sharpe {num(r.base_sharpe)} → {num(r.pair_sharpe)} · worst drop {pct(r.base_drawdown)} → {pct(
              r.pair_drawdown
            )} · correlation {num(r.correlation)} · {date(r.from)} – {date(r.to)}
          </span>
        </div>
        <button
          type="button"
          phx-click="toggle_mate"
          phx-value-key={r.play.key}
          class={[
            "col-span-2 min-h-11 rounded-field border px-4 text-[15px] font-semibold sm:col-span-1",
            if(r.play.key in @selected,
              do: "border-primary text-primary",
              else: "border-base-300 hover:border-primary"
            )
          ]}
        >
          {if r.play.key in @selected, do: "On the team ✓", else: "Add to team"}
        </button>
        <div :if={Together.next_step(r.play)} class="col-span-2 sm:col-span-3">
          <.next_step play={r.play} />
        </div>
      </li>
    </ol>
    """
  end

  attr :play, :map, required: true

  defp play_status(assigns) do
    ~H"""
    <span class={["text-[13px] font-medium", status_class(@play.status)]}>
      {status_words(@play.status)}
    </span>
    """
  end

  # The one next step a play offers (`Together.next_step/1`). Switching on
  # stays on the strategy's page, where the switch is.
  attr :play, :map, required: true

  defp next_step(assigns) do
    assigns = assign(assigns, step: Together.next_step(assigns.play))

    ~H"""
    <.link
      :if={@step == :open}
      navigate={~p"/strategies/#{@play.live_id}"}
      class="inline-flex min-h-11 items-center self-start rounded-field border border-primary px-3 text-[14px] font-semibold text-primary hover:brightness-110"
    >
      Open to switch on
    </.link>
    <button
      :if={@step == :promote}
      type="button"
      phx-click="promote"
      phx-value-key={@play.key}
      class="min-h-11 self-start rounded-field bg-primary px-3 text-[14px] font-semibold text-primary-content hover:brightness-110"
    >
      Add to live (switched off)
    </button>
    <button
      :if={@step == :retest}
      type="button"
      phx-click="retest"
      phx-value-key={@play.key}
      data-confirm={retest_confirm(@play)}
      class="min-h-11 self-start rounded-field border border-base-300 px-3 text-[14px] font-semibold hover:border-primary"
    >
      Re-test with today's rules
    </button>
    <.resume_button
      :if={@step == :resume}
      config_id={@play.config_id}
      stage={elem(@play.status, 1)}
      class="min-h-11 self-start rounded-field border border-base-300 px-3 text-[14px] font-semibold hover:border-primary"
    />
    """
  end

  attr :count, :integer, required: true
  attr :shown, :boolean, required: true

  defp old_toggle(assigns) do
    ~H"""
    <button
      :if={@count > 0}
      type="button"
      phx-click="old"
      aria-pressed={to_string(@shown)}
      class="self-start text-[13px] font-medium text-primary hover:brightness-110"
    >
      <.t
        :if={!@shown}
        {copy("Show old tests (%{count}): tested before the current rules", count: @count)}
      />
      <.t :if={@shown} {copy("Hide old tests")} />
    </button>
    """
  end

  # --- words -----------------------------------------------------------------

  defp visible(tested, true), do: tested
  defp visible(tested, false), do: Enum.reject(tested, & &1.old)

  defp status_words(:trading), do: "On, trading"
  defp status_words(:switched_off), do: "Added, switched off"
  defp status_words(:ready), do: "Passed every test: ready to add to live"
  defp status_words(:old), do: "Old test (before the current rules): re-test it first"
  defp status_words({:testing, stage}), do: "Still testing (#{stage_name(stage)})"

  defp status_words({:stuck, stage}),
    do:
      "Stopped part-way at the #{stage_name(stage)} (the tester restarted or the job was cleared): nothing is running it."

  defp status_words({:failed, stage, result}) when stage in [:backtest, :walk_forward],
    do: "Failed the #{stage_name(stage)}#{because(result)}"

  defp status_words({:failed, stage, result}),
    do: "Passed walk-forward, failed the #{stage_name(stage)}#{because(result)}"

  defp because(result) do
    case missed_words(result) do
      nil -> ""
      words -> ": #{words}"
    end
  end

  defp status_class(:trading), do: "text-primary"
  defp status_class(:ready), do: "text-success"
  defp status_class({:failed, _stage, _result}), do: "text-error"
  defp status_class(status) when status in [:old] or is_tuple(status), do: "text-warning"
  defp status_class(_switched_off), do: "text-muted"

  defp team_count([]), do: "nobody yet"

  defp team_count(team) do
    trading = Enum.count(team, & &1.enabled)
    n = length(team)

    "#{n} #{if n == 1, do: "strategy", else: "strategies"}" <>
      if(trading == n, do: ", all trading now", else: ", #{trading} trading now")
  end

  defp matches?(_play, ""), do: true

  defp matches?(play, query) do
    q = String.downcase(query)

    Enum.any?(
      [play.name, play.instrument, play.timeframe],
      &String.contains?(String.downcase(&1), q)
    )
  end

  # Each play's numbers alone and its tag in the team, by key.
  defp alone_by_key(nil), do: %{}

  defp alone_by_key(%{plays: plays} = result) do
    o = result.with_rules || result.without_rules
    best = plays |> Enum.map(& &1.alone.annual_return) |> Enum.max(fn -> 0.0 end)
    carrier_key = plays |> carrier() |> then(&(&1 && &1.key))

    Map.new(plays, fn p ->
      a = p.alone

      tag =
        cond do
          length(plays) == 1 -> :solo
          a.annual_return <= 0 -> :loses
          p.key == carrier_key -> :carries
          a.annual_return < best / 4 -> :small
          true -> :pulls
        end

      {p.key, Map.merge(a, %{tag: tag, together: Map.get(o.taken_by_play, p.key, 0)})}
    end)
  end

  defp tag_words(:solo), do: "on its own"
  defp tag_words(:carries), do: "carries the team"
  defp tag_words(:pulls), do: "pulls its weight"
  defp tag_words(:small), do: "small helper"
  defp tag_words(:loses), do: "loses money alone"

  defp tag_class(:carries), do: "bg-primary/15 text-primary"
  defp tag_class(:loses), do: "bg-error/15 text-error"
  defp tag_class(_tag), do: "bg-neutral text-muted"

  defp headline(result, o) do
    base =
      "Your team made about #{signed_pct(o.annual_return)} a year, and the worst it ever got was " <>
        "#{pct(o.max_drawdown)} below its high."

    case carrier(result.plays) do
      nil -> base
      p -> "#{base} One strategy does most of the work: #{short(Together.label(p))}."
    end
  end

  # Compared without the safety rules on either side (each play alone runs
  # without them), with the same margin step 3 uses for "steadier".
  defp team_words(result, _o) do
    best = Enum.max_by(result.plays, & &1.alone.annual_sharpe)
    gain = result.without_rules.annual_sharpe - best.alone.annual_sharpe
    name = short(Together.label(best))

    cond do
      gain >= @steadier ->
        "Together they're steadier than any one of them alone: the bad days of one are covered by the others. " <>
          "That's what a good team looks like."

      gain > -@steadier ->
        "The team is about as steady as #{name} alone: the others don't add much. A teammate that moves on its " <>
          "own (step 3) would help more than another one like them."

      true ->
        "The team is less steady than #{name} alone: the others move too much alike or add too little. A " <>
          "teammate that moves on its own (step 3) would help more than another one like them."
    end
  end

  # The play making at least half of what the team's winners make.
  defp carrier(plays) when length(plays) < 2, do: nil

  defp carrier(plays) do
    positive = plays |> Enum.map(&max(&1.alone.annual_return, 0.0)) |> Enum.sum()
    best = Enum.max_by(plays, & &1.alone.annual_return)
    if positive > 0 and best.alone.annual_return / positive >= 0.5, do: best
  end

  defp carry(plays) do
    top = plays |> Enum.map(&abs(&1.alone.annual_return)) |> Enum.max(fn -> 0.0 end)

    plays
    |> Enum.sort_by(& &1.alone.annual_return, :desc)
    |> Enum.map(fn p ->
      share = if top > 0, do: abs(p.alone.annual_return) / top * 100, else: 0

      %{
        name: short(Together.label(p)),
        annual_return: p.alone.annual_return,
        width: Float.round(max(share, 1.0), 1)
      }
    end)
  end

  defp steadiness(sharpe) when sharpe < 0, do: {"Losing", 1, "It lost money over these years."}

  defp steadiness(sharpe) when sharpe < 0.3,
    do: {"Shaky", 1, "Gains came with big swings, or not at all."}

  defp steadiness(sharpe) when sharpe < 0.7, do: {"Okay", 2, "Ups and downs, but it got there."}

  defp steadiness(sharpe) when sharpe < 1.5,
    do: {"Good", 3, "Gains came more smoothly than most. Not so smooth it's suspicious."}

  defp steadiness(_sharpe),
    do:
      {"Too smooth?", 4,
       "Smoother than real trading usually is: check it isn't fitted to the past."}

  defp pause_words(_o, nil), do: "No drawdown pause set."

  defp pause_words(%{pause_trips: []}, limits),
    do: "Your #{trim(limits.drawdown_pause_pct)}% pause never tripped"

  defp pause_words(%{pause_trips: trips}, limits),
    do:
      "Your #{trim(limits.drawdown_pause_pct)}% pause would have tripped #{times(length(trips))}"

  defp rules_lines(%{with_rules: nil}, _limits),
    do: ["The safety rules aren't set up yet, so this ran without them."]

  defp rules_lines(%{with_rules: w, without_rules: wo}, limits) do
    blocked = w.blocked.risk_budget + w.blocked.group_cap

    stepped_in =
      if blocked == 0 do
        "The #{trim(limits.risk_budget_pct)}% risk budget and the group limit of #{limits.max_open_per_group} never had to step in."
      else
        "They blocked #{blocked} trades: #{w.blocked.risk_budget} for the risk budget, #{w.blocked.group_cap} for the " <>
          "group limit. Without them the account makes #{signed_pct(wo.annual_return)} a year with a worst drop of " <>
          "#{pct(wo.max_drawdown)}."
      end

    trips =
      case {w.pause_trips, w.breaker_trips} do
        {[], []} ->
          "The #{trim(limits.drawdown_pause_pct)}% pause never tripped, and no strategy hit the circuit breaker."

        {pause, breaker} ->
          pause_part =
            if pause == [],
              do: "The pause never tripped",
              else:
                "The pause would have tripped #{times(length(pause))} (first #{date(hd(pause))})"

          breaker_part =
            if breaker == [],
              do: "no strategy hit the circuit breaker",
              else:
                "the circuit breaker would have switched off " <>
                  (breaker
                   |> Enum.frequencies_by(& &1.name)
                   |> Enum.map_join(", ", fn {name, k} -> "#{short(name)} #{times(k)}" end))

          "#{pause_part}, and #{breaker_part}. The replay assumes you pressed resume straight away."
      end

    [stepped_in, trips]
  end

  defp mate_alike(c) when is_number(c) and abs(c) < 0.2, do: "moves on its own"
  defp mate_alike(c) when is_number(c) and c <= -0.2, do: "moves opposite"
  defp mate_alike(c), do: Together.alike_words(c)

  defp mate_words(%{sharpe_gain: gain}) when gain >= 0.3,
    do: "Much steadier together: the pair is a lot smoother than it alone."

  defp mate_words(%{sharpe_gain: gain}) when gain >= @steadier,
    do: "A little steadier together."

  defp mate_words(%{sharpe_gain: gain}) when gain > -@steadier,
    do: "No real help: about as steady as it alone."

  defp mate_words(_row), do: "Less steady together: skip it."

  defp alike_class(c) when is_number(c) and c < 0.2, do: "bg-primary/15 text-primary"
  defp alike_class(c) when is_number(c) and c < 0.5, do: "bg-warning/15 text-warning"
  defp alike_class(c) when is_number(c), do: "bg-error/15 text-error"
  defp alike_class(_none), do: "bg-neutral text-muted"

  # "Index dip-buy · SPX500_USD D" as "Index dip-buy · SPX500_USD".
  defp short(label), do: label |> String.split(" ") |> Enum.drop(-1) |> Enum.join(" ")

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  defp trim(value) when is_float(value) and value == trunc(value),
    do: Integer.to_string(trunc(value))

  defp trim(value), do: to_string(value)

  # A re-test is one more luck-check try; if any run of it already reached
  # the holdout, it's also one more look at that sealed data, which is
  # meant to be looked at once: say so before the click.
  defp retest_confirm(play) do
    base =
      "Re-test #{Together.label(play)} with today's rules? Every test runs again as a new run; " <>
        "the old one stays as history. It counts as one more try in the luck check, which raises " <>
        "the bar a little for every version of this idea."

    if play.holdout_seen,
      do:
        base <>
          " It has already been judged on the holdout (the year of data kept aside for one final look). " <>
          "If it gets that far again, that's a second look at the same data, so a pass there means less.",
      else: base
  end
end
