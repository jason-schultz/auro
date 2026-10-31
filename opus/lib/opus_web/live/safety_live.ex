defmodule OpusWeb.SafetyLive do
  @moduledoc """
  The account safety rules (`Opus.Trading.AccountLimits`), as guardrails:

  - a banner that says in one line whether anything needs you (a pause, a
    strategy switched off, or all clear);
  - one card per rule, the rule written as a sentence with its number in
    it to edit, where the account stands against it now, and what it
    protects from;
  - a save bar that appears once a number changes: tightening saves as is,
    loosening says what it lets through and the button says so;
  - each switched-on strategy against the circuit breaker (its last trades
    as dots, its losing streak, its exemption);
  - the history of every change.

  "Show the numbers" adds the exact figures behind each card. Every save
  goes to the engine at once (`Opus.Trading.RulesEngine`).
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Trading.{
    AccountLimits,
    AccountPause,
    CircuitBreaker,
    RulesEngine,
    Safety,
    StrategyWords
  }

  @breaker_keys [:breaker_losses, :breaker_drawdown_pct, :breaker_window_days]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Safety",
        loaded: false,
        overview: nil,
        values: %{},
        changes: [],
        errors: %{},
        exempting: nil,
        numbers: false
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    overview = Safety.overview()

    assign(socket,
      loaded: true,
      overview: overview,
      values: overview && form_values(overview.limits),
      changes: [],
      errors: %{},
      exempting: nil
    )
  end

  defp form_values(limits),
    do: Map.new(AccountLimits.keys(), &{Atom.to_string(&1), number(Map.fetch!(limits, &1))})

  @impl true
  def handle_event("numbers", _params, socket),
    do: {:noreply, update(socket, :numbers, &(!&1))}

  def handle_event("edit", params, %{assigns: %{overview: %{limits: limits}}} = socket) do
    values =
      Map.merge(
        socket.assigns.values,
        Map.take(params, Enum.map(AccountLimits.keys(), &Atom.to_string/1))
      )

    case AccountLimits.diff(limits, values) do
      {:ok, changes} -> {:noreply, assign(socket, values: values, changes: changes, errors: %{})}
      {:error, errors} -> {:noreply, assign(socket, values: values, changes: [], errors: errors)}
    end
  end

  def handle_event(
        "save",
        _params,
        %{assigns: %{changes: [_ | _] = changes, errors: errors}} = socket
      )
      when errors == %{} do
    case AccountLimits.save(changes) do
      {:ok, _limits} ->
        RulesEngine.recompute()
        if Enum.any?(changes, &(&1.key in @breaker_keys)), do: CircuitBreaker.recompute()

        {:noreply,
         socket |> put_flash(:info, "Saved. The engine has the new guardrails.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("undo", _params, socket), do: {:noreply, load(socket)}

  def handle_event("exempt", %{"id" => id, "to" => "true"}, socket),
    do: {:noreply, assign(socket, exempting: id)}

  def handle_event("exempt", %{"id" => id, "to" => "false"}, socket),
    do: set_exempt(socket, id, false)

  def handle_event("confirm_exempt", _params, %{assigns: %{exempting: id}} = socket)
      when is_binary(id),
      do: set_exempt(socket, id, true)

  def handle_event("cancel_exempt", _params, socket),
    do: {:noreply, assign(socket, exempting: nil)}

  def handle_event("resume", _params, socket) do
    AccountPause.clear()
    RulesEngine.recompute()
    {:noreply, socket |> put_flash(:info, "Trading resumed; rules recomputing.") |> load()}
  end

  defp set_exempt(socket, id, exempt) do
    case AccountLimits.set_exempt(id, exempt) do
      {:ok, _} ->
        CircuitBreaker.recompute()
        {:noreply, socket |> put_flash(:info, "Saved.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex max-w-[1120px] flex-col gap-7">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="flex max-w-[700px] flex-col gap-1.5">
            <h1 class="text-[32px] font-bold tracking-tight">
              <.t {copy("Account safety")} />
            </h1>
            <p class="m-0 text-[16px] text-muted">
              <.t {copy(
                "Four guardrails watch the whole account, whatever the strategies do. They never pick trades; they only stop new ones. Nothing switches back on by itself: you decide."
              )} />
            </p>
          </div>
          <.numbers_switch on={@numbers} />
        </header>

        <p :if={@loaded and @overview == nil} class="text-[14px] text-muted">
          <.t {copy("The safety limits aren't set up yet: run the database migrations.")} />
        </p>

        <%= if @overview do %>
          <.banner overview={@overview} />

          <section aria-labelledby="rules-h" class="flex flex-col gap-3.5">
            <div class="flex flex-wrap items-baseline justify-between gap-2.5">
              <h2 id="rules-h" class="text-[22px] font-bold">
                <.t {copy("Your guardrails")} />
              </h2>
              <span class="text-[14px] text-muted">
                Change a number to edit. Lower is safer, except the breaker's window.
              </span>
            </div>

            <form id="guardrails" phx-change="edit" phx-submit="save" class="flex flex-col gap-3.5">
              <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,500px),1fr))] gap-3.5">
                <.rule_card
                  title={copy("Drawdown pause")}
                  badge={badge(@changes, [:drawdown_pause_pct])}
                >
                  <:sentence>
                    Pause every strategy if the account falls
                    <.number_input
                      key={:drawdown_pause_pct}
                      values={@values}
                      errors={@errors}
                      label="Drawdown pause percent"
                    /> % from its high
                  </:sentence>
                  <:now>
                    <%= if d = @overview.drawdown do %>
                      <.meter
                        label="Now"
                        words={"#{pct(d.drawdown)} below the high"}
                        used={d.drawdown}
                        limit={@overview.limits.drawdown_pause_pct / 100}
                      />
                      <p :if={@numbers} class="m-0 text-[12px] tabular-nums text-muted">
                        NAV {money(d.nav)} · high {money(d.peak)} since {date(d.from)} · trips at {money(
                          d.peak * (1 - @overview.limits.drawdown_pause_pct / 100)
                        )}
                      </p>
                    <% else %>
                      <span class="text-[13px] text-muted">No account snapshot yet.</span>
                    <% end %>
                  </:now>
                  <:protects>
                    a bad stretch across everything at once, like June's energy blowup.
                  </:protects>
                </.rule_card>

                <.rule_card title={copy("Risk budget")} badge={badge(@changes, [:risk_budget_pct])}>
                  <:sentence>
                    Never risk more than
                    <.number_input
                      key={:risk_budget_pct}
                      values={@values}
                      errors={@errors}
                      label="Risk budget percent"
                      step="0.5"
                    /> % of the account at once
                  </:sentence>
                  <:now>
                    <.meter
                      label="Now"
                      words={risk_words(@overview.risk)}
                      used={@overview.risk.used}
                      limit={@overview.risk.budget}
                    />
                    <p :if={@numbers} class="m-0 text-[12px] tabular-nums text-muted">
                      Per trade: {Enum.map_join(
                        @overview.risk.per_strategy,
                        " · ",
                        &"#{&1.instrument} #{pct(&1.risk)}"
                      )} · all at once {pct(@overview.risk.all_at_once)}
                    </p>
                  </:now>
                  <:protects>
                    many trades losing on the same day. A trade's risk is what it loses if its stop is hit.
                  </:protects>
                </.rule_card>

                <.rule_card title={copy("Group limit")} badge={badge(@changes, [:max_open_per_group])}>
                  <:sentence>
                    At most
                    <.number_input
                      key={:max_open_per_group}
                      values={@values}
                      errors={@errors}
                      label="Most open trades per group"
                    /> open trades in one group
                  </:sentence>
                  <:now>
                    <div
                      :for={g <- @overview.groups}
                      class="flex items-center justify-between gap-3 text-[13px]"
                    >
                      <span>
                        {group_name(g.group)}
                        <span class="text-muted">· {Enum.join(g.instruments, ", ")}</span>
                      </span>
                      <span
                        class="flex gap-1"
                        aria-label={"#{g.open} of #{@overview.limits.max_open_per_group} open"}
                      >
                        <span
                          :for={slot <- 1..@overview.limits.max_open_per_group//1}
                          class={[
                            "h-2 w-[18px] rounded-sm",
                            if(slot <= g.open, do: "bg-warning", else: "bg-neutral")
                          ]}
                        />
                      </span>
                    </div>
                    <span :if={@overview.groups == []} class="text-[13px] text-muted">No strategy is switched on.</span>
                    <span :if={length(@overview.groups) == 1} class="text-[13px] text-muted">
                      All your switched-on strategies trade {String.downcase(
                        group_name(hd(@overview.groups).group)
                      )}, so they share this one group.
                    </span>
                  </:now>
                  <:protects>
                    betting on one thing several times over: instruments in one group fall together in a sell-off.
                  </:protects>
                </.rule_card>

                <.rule_card title={copy("Circuit breaker")} badge={badge(@changes, breaker_keys())}>
                  <:sentence>
                    Switch a strategy off after
                    <.number_input
                      key={:breaker_losses}
                      values={@values}
                      errors={@errors}
                      label="Losses in a row"
                    /> losses in a row,
                  </:sentence>
                  <:sentence>
                    or if it loses
                    <.number_input
                      key={:breaker_drawdown_pct}
                      values={@values}
                      errors={@errors}
                      label="Loss percent over the window"
                    /> % within
                    <.number_input
                      key={:breaker_window_days}
                      values={@values}
                      errors={@errors}
                      label="Window in days"
                    /> days
                  </:sentence>
                  <:protects>
                    one strategy that has stopped working. The loss is its trades' price moves added up, not
                    the account's: a strategy that puts half the account into each trade loses about half that.
                    Each one's standing is below.
                  </:protects>
                </.rule_card>
              </div>

              <div
                :if={@changes != [] or @errors != %{}}
                role="region"
                aria-label="Unsaved changes"
                class={[
                  "flex flex-wrap items-center gap-3.5 rounded-box border bg-base-200 px-5 py-4",
                  if(looser?(@changes), do: "border-warning", else: "border-primary")
                ]}
              >
                <div class="flex min-w-[260px] flex-1 flex-col gap-0.5">
                  <span class="font-semibold">{save_title(@changes, @errors)}</span>
                  <span class="text-[14px] text-muted">{save_detail(@changes, @errors)}</span>
                </div>
                <button
                  type="button"
                  phx-click="undo"
                  class="min-h-11 rounded-field border border-base-300 px-4 text-[15px] font-semibold hover:border-primary"
                >
                  <.t {copy("Undo")} />
                </button>
                <button
                  type="submit"
                  disabled={@errors != %{}}
                  class={[
                    "min-h-11 rounded-field px-4 text-[15px] font-semibold disabled:opacity-50",
                    if(looser?(@changes),
                      do: "bg-warning text-warning-content",
                      else: "bg-primary text-primary-content"
                    )
                  ]}
                >
                  <.t :if={looser?(@changes)} {copy("Yes, loosen it")} />
                  <.t :if={!looser?(@changes)} {copy("Save")} />
                </button>
              </div>
            </form>
          </section>

          <section aria-labelledby="breaker-h" class="flex flex-col gap-3">
            <h2 id="breaker-h" class="text-[22px] font-bold">
              <.t {copy("Each strategy and the circuit breaker")} />
            </h2>
            <ul class="m-0 list-none rounded-box border border-base-300 bg-base-200 p-0">
              <li
                :for={b <- @overview.breakers}
                id={"breaker-#{b.id}"}
                class="flex flex-col gap-3 border-t border-neutral px-5 py-3.5 first:border-t-0"
              >
                <div class="grid grid-cols-1 items-center gap-x-4 gap-y-2 sm:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_minmax(0,1.2fr)_auto]">
                  <div class="flex min-w-0 flex-col">
                    <.link
                      navigate={~p"/strategies/#{b.id}"}
                      class="truncate font-semibold hover:text-primary"
                    >
                      {b.name}
                    </.link>
                    <span class="text-[13px] text-muted">
                      {b.instrument} · {StrategyWords.timeframe(b.granularity)}
                    </span>
                  </div>
                  <div class="flex flex-col gap-1">
                    <span class="flex min-h-3 gap-1" aria-label={dots_label(b.recent)}>
                      <span
                        :for={won <- b.recent}
                        class={["size-3 rounded-full", if(won, do: "bg-success", else: "bg-error")]}
                      />
                    </span>
                    <span class="text-[12px] text-muted">{streak_words(b)}</span>
                  </div>
                  <span class="text-[14px]">
                    {standing_words(b, @overview.limits, @overview.min_trades, @numbers)}
                  </span>
                  <div class="flex items-center justify-end gap-2.5">
                    <span class={["rounded-full px-2.5 py-1 text-[13px] font-medium", breaker_tone(b)]}>
                      {chip_words(b)}
                    </span>
                    <button
                      :if={!b.suspension}
                      type="button"
                      phx-click="exempt"
                      phx-value-id={b.id}
                      phx-value-to={to_string(!b.circuit_breaker_exempt)}
                      class="min-h-11 rounded-field border border-base-300 px-3 text-[13px] font-semibold hover:border-primary"
                    >
                      {if b.circuit_breaker_exempt, do: "Use the breaker", else: "Exempt it"}
                    </button>
                    <.link
                      :if={b.suspension}
                      navigate={~p"/strategies/#{b.id}"}
                      class="inline-flex min-h-11 items-center rounded-field border border-base-300 px-3 text-[13px] font-semibold hover:border-primary"
                    >
                      Look and reset
                    </.link>
                  </div>
                </div>
                <div
                  :if={@exempting == b.id}
                  role="alert"
                  class="flex flex-wrap items-center gap-3 rounded-box border border-warning bg-base-100 px-4 py-3"
                >
                  <span class="min-w-[240px] flex-1 text-[14px]">
                    This loosens the circuit breaker: {b.name} on {b.instrument} keeps trading through losing streaks and won't be switched off.
                  </span>
                  <button
                    type="button"
                    phx-click="cancel_exempt"
                    class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] font-semibold"
                  >
                    <.t {copy("Cancel")} />
                  </button>
                  <button
                    type="button"
                    phx-click="confirm_exempt"
                    class="min-h-11 rounded-field bg-warning px-4 text-[14px] font-semibold text-warning-content"
                  >
                    <.t {copy("Yes, loosen it")} />
                  </button>
                </div>
              </li>
              <li :if={@overview.breakers == []} class="px-5 py-3.5 text-[14px] text-muted">
                No strategy is switched on.
              </li>
            </ul>
            <p class="m-0 text-[13px] text-muted">
              Dots are the last six closed trades since its last reset, oldest on the left: green won, red lost.
            </p>
          </section>

          <section aria-labelledby="hist-h" class="flex flex-col gap-3">
            <h2 id="hist-h" class="text-[22px] font-bold">
              <.t {copy("What changed, and when")} />
            </h2>
            <ol class="m-0 list-none rounded-box border border-base-300 bg-base-200 px-5 py-2">
              <li
                :for={c <- @overview.changes}
                class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1 border-b border-neutral py-3 sm:grid-cols-[130px_minmax(0,1fr)_auto]"
              >
                <span class="text-[13px] text-muted">{stamp(c.changed_at)}</span>
                <span class="col-span-2 sm:col-span-1">{change_words(c)}</span>
                <span class={["rounded-full px-2.5 py-1 text-[13px] font-medium", change_class(c)]}>
                  {if loosened?(c), do: "looser", else: "tighter"}
                </span>
              </li>
              <li class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 py-3 sm:grid-cols-[130px_minmax(0,1fr)_auto]">
                <span class="text-[13px] text-muted">{date(@overview.limits.since)}</span>
                <span class="col-span-2 sm:col-span-1">Guardrails switched on.</span>
                <span class="rounded-full bg-neutral px-2.5 py-1 text-[13px] font-medium text-muted">start</span>
              </li>
            </ol>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :on, :boolean, required: true

  @doc false
  def numbers_switch(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="numbers"
      aria-pressed={to_string(@on)}
      class="inline-flex min-h-11 items-center gap-2.5 rounded-field border border-base-300 bg-base-200 px-4 text-[15px] font-semibold"
    >
      <span class={[
        "relative inline-block h-5 w-[34px] rounded-full",
        if(@on, do: "bg-primary", else: "bg-base-300")
      ]}>
        <span class={[
          "absolute top-0.5 size-4 rounded-full bg-base-content",
          if(@on, do: "left-4", else: "left-0.5")
        ]} />
      </span>
      <.t {copy("Show the numbers")} />
    </button>
    """
  end

  attr :overview, :map, required: true

  defp banner(%{overview: %{pause: %{} = pause}} = assigns) do
    assigns = assign(assigns, down: AccountPause.drawdown(pause.peak_nav, pause.nav))

    ~H"""
    <section
      role="alert"
      class="flex flex-wrap items-center gap-4 rounded-box border border-error bg-base-200 px-6 py-5"
    >
      <div class="flex min-w-[240px] flex-1 flex-col gap-0.5">
        <span class="text-[20px] font-bold text-error">
          Trading is paused: the account fell {pct(@down)} from its high
        </span>
        <span class="text-muted">
          No strategy opens a trade until you resume. Open trades keep their stops. Look at what lost first.
        </span>
      </div>
      <button
        type="button"
        phx-click="resume"
        class="min-h-11 rounded-field border border-base-300 px-4 text-[15px] font-semibold hover:border-primary"
      >
        <.t {copy("Resume trading")} />
      </button>
    </section>
    """
  end

  defp banner(assigns) do
    assigns = assign(assigns, off: Enum.filter(assigns.overview.breakers, & &1.suspension))

    ~H"""
    <section
      role="status"
      class={[
        "flex flex-wrap items-center gap-4 rounded-box border bg-base-200 px-6 py-5",
        if(@off == [], do: "border-primary", else: "border-warning")
      ]}
    >
      <span class={[
        "flex size-12 flex-none items-center justify-center rounded-full",
        if(@off == [], do: "bg-primary/15 text-primary", else: "bg-warning/15 text-warning")
      ]}>
        <.icon
          name={if(@off == [], do: "hero-check", else: "hero-exclamation-triangle")}
          class="size-6"
        />
      </span>
      <div class="flex min-w-[240px] flex-1 flex-col gap-0.5">
        <span class="text-[20px] font-bold">
          {if @off == [],
            do: "All clear: nothing is holding your strategies back",
            else:
              "#{length(@off)} #{if length(@off) == 1, do: "strategy is", else: "strategies are"} switched off by the circuit breaker"}
        </span>
        <span class="text-muted">{banner_words(@overview, @off)}</span>
      </div>
    </section>
    """
  end

  slot :sentence, required: true
  slot :now
  slot :protects, required: true
  attr :title, :map, required: true, doc: "copy/1"
  attr :badge, :atom, required: true

  defp rule_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-5">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-[17px] font-bold"><.t {@title} /></h3>
        <span class={["rounded-full px-2.5 py-1 text-[13px] font-medium", badge_class(@badge)]}>
          {badge_words(@badge)}
        </span>
      </div>
      <p :for={sentence <- @sentence} class="m-0 flex flex-wrap items-center gap-2.5 text-[16px]">
        {render_slot(sentence)}
      </p>
      <div :if={@now != []} class="flex flex-col gap-1.5">{render_slot(@now)}</div>
      <p class="m-0 text-[13px] text-muted">
        <strong class="font-semibold text-base-content">Protects you from</strong> {render_slot(
          @protects
        )}
      </p>
    </div>
    """
  end

  attr :key, :atom, required: true
  attr :values, :map, required: true
  attr :errors, :map, required: true
  attr :label, :string, required: true
  attr :step, :string, default: "any"

  defp number_input(assigns) do
    {min, max} = AccountLimits.range(assigns.key)
    assigns = assign(assigns, min: min, max: max, error: assigns.errors[assigns.key])

    ~H"""
    <span class="inline-flex flex-col">
      <input
        type="number"
        name={Atom.to_string(@key)}
        value={@values[Atom.to_string(@key)]}
        min={@min}
        max={@max}
        step={@step}
        aria-label={@label}
        aria-invalid={to_string(@error != nil)}
        phx-debounce="300"
        class={[
          "min-h-11 w-[72px] rounded-field border bg-base-100 px-1.5 text-center text-[20px] font-bold",
          if(@error, do: "border-error", else: "border-base-300")
        ]}
      />
      <span :if={@error} class="text-[12px] text-error">{@error}</span>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :words, :string, required: true
  attr :used, :float, required: true
  attr :limit, :float, required: true

  defp meter(assigns) do
    assigns = assign(assigns, share: min(assigns.used / max(assigns.limit, 1.0e-9), 1.0))

    ~H"""
    <div class="flex justify-between text-[13px]">
      <span class="text-muted">{@label}</span><span>{@words}</span>
    </div>
    <div
      role="meter"
      aria-valuemin="0"
      aria-valuemax={@limit}
      aria-valuenow={@used}
      aria-label={@words}
      class="h-2 w-full overflow-hidden rounded-full bg-neutral"
    >
      <div
        class={["h-full rounded-full", if(@share >= 2 / 3, do: "bg-warning", else: "bg-success")]}
        style={"width: #{Float.round(max(@share, 0.01) * 100, 1)}%"}
      />
    </div>
    """
  end

  # --- words ----------------------------------------------------------------

  defp banner_words(overview, []) do
    trades =
      case overview.risk.trades do
        0 -> "No trade is open"
        1 -> "1 trade is open"
        n -> "#{n} trades are open"
      end

    high =
      case overview.drawdown do
        %{drawdown: d} when d < 0.0005 -> "the account is at its high"
        %{drawdown: d} -> "the account is #{pct(d)} below its high"
        nil -> "there's no account snapshot yet"
      end

    "#{trades}, #{high}, and no strategy is switched off. Nothing to do."
  end

  defp banner_words(_overview, off),
    do:
      "#{Enum.map_join(off, ", ", &"#{&1.name} on #{&1.instrument}")}: look at its recent trades on its page, " <>
        "then reset it if you still want it trading. Everything else keeps going."

  defp badge(changes, keys) do
    case Enum.filter(changes, &(&1.key in keys)) do
      [] -> :on
      mine -> if Enum.any?(mine, & &1.loosens?), do: :looser, else: :tighter
    end
  end

  defp badge_words(:on), do: "on"
  defp badge_words(:looser), do: "looser: asks first"
  defp badge_words(:tighter), do: "tighter: saves at once"

  defp badge_class(:on), do: "bg-neutral text-muted"
  defp badge_class(:looser), do: "bg-warning/15 text-warning"
  defp badge_class(:tighter), do: "bg-primary/15 text-primary"

  defp breaker_keys, do: @breaker_keys

  defp looser?(changes), do: Enum.any?(changes, & &1.loosens?)

  defp save_title(_changes, errors) when errors != %{}, do: "A number is out of range"
  defp save_title([_], _errors), do: "1 unsaved change"
  defp save_title(changes, _errors), do: "#{length(changes)} unsaved changes"

  defp save_detail(_changes, errors) when errors != %{},
    do: "Fix the number marked in red, or undo."

  defp save_detail(changes, _errors) do
    case Enum.filter(changes, & &1.loosens?) do
      [] ->
        "Tighter guardrails: safe to save straight away. The engine gets them at once."

      looser ->
        "This loosens the #{Enum.map_join(looser, " and ", &String.downcase(setting_name(&1.key)))}: " <>
          "bigger losses can happen before anything stops them."
    end
  end

  defp risk_words(%{trades: 0}), do: "No trade open · 0% used"
  defp risk_words(%{trades: 1, used: used}), do: "1 trade open · #{pct(used)} used"
  defp risk_words(%{trades: n, used: used}), do: "#{n} trades open · #{pct(used)} used"

  defp dots_label([]), do: "No closed trades yet"
  defp dots_label(recent), do: "Last #{length(recent)} trades: #{Enum.count(recent, & &1)} won"

  defp streak_words(%{recent: []}), do: "No closed trades yet"

  defp streak_words(%{streak: 0, recent: recent}) do
    wins = recent |> Enum.reverse() |> Enum.take_while(& &1) |> length()

    if wins == length(recent),
      do: "Won its last #{wins}",
      else: "#{wins} #{if wins == 1, do: "win", else: "wins"} since its last loss"
  end

  defp streak_words(%{streak: n}), do: "#{n} #{if n == 1, do: "loss", else: "losses"} in a row"

  defp standing_words(%{suspension: %{trigger_detail: detail}}, _limits, _min, _numbers),
    do: "Switched off: #{detail}"

  defp standing_words(%{window_trades: 0}, limits, _min, _numbers),
    do: "No trades in the last #{limits.breaker_window_days} days"

  defp standing_words(b, limits, _min, true),
    do:
      "Last #{limits.breaker_window_days} days: #{signed_pct(b.window_sum, 2)} of price over #{b.window_trades} trades"

  defp standing_words(%{window_trades: n}, limits, min, false) when n < min,
    do:
      "#{n} #{if n == 1, do: "trade", else: "trades"} in the last #{limits.breaker_window_days} days: " <>
        "too few for the loss limit yet (it needs #{min})"

  defp standing_words(b, limits, _min, false) do
    days = "the last #{limits.breaker_window_days} days"

    cond do
      b.window_sum >= 0 ->
        "Up over #{days}"

      b.window_sum > -limits.breaker_drawdown_pct / 200 ->
        "Slightly down over #{days}, far from the limit"

      true ->
        "Down over #{days}, past halfway to the limit"
    end
  end

  defp chip_words(%{suspension: %{}}), do: "switched off"
  defp chip_words(%{circuit_breaker_exempt: true}), do: "exempt"
  defp chip_words(_b), do: "watched"

  defp breaker_tone(%{suspension: %{}}), do: "bg-error/15 text-error"
  defp breaker_tone(%{circuit_breaker_exempt: true}), do: "bg-warning/15 text-warning"
  defp breaker_tone(_b), do: "bg-neutral text-muted"

  defp setting_name(:drawdown_pause_pct), do: "Drawdown pause"
  defp setting_name(:risk_budget_pct), do: "Risk budget"
  defp setting_name(:max_open_per_group), do: "Group limit"
  defp setting_name(:breaker_losses), do: "Breaker: losses in a row"
  defp setting_name(:breaker_drawdown_pct), do: "Breaker: loss over the window"
  defp setting_name(:breaker_window_days), do: "Breaker: window"

  defp unit(key) when key in [:drawdown_pause_pct, :risk_budget_pct, :breaker_drawdown_pct],
    do: "%"

  defp unit(:breaker_window_days), do: " days"
  defp unit(_key), do: ""

  defp loosened?(c), do: AccountLimits.loosens?(c.setting, c.old_value, c.new_value)

  defp change_class(c),
    do: if(loosened?(c), do: "bg-warning/15 text-warning", else: "bg-primary/15 text-primary")

  defp change_words(%{setting: "circuit_breaker_exempt", subject: subject, new_value: "true"}),
    do: "#{subject}: exempt from the circuit breaker"

  defp change_words(%{setting: "circuit_breaker_exempt", subject: subject}),
    do: "#{subject}: back under the circuit breaker"

  defp change_words(%{setting: setting, old_value: old, new_value: new}) do
    key = String.to_existing_atom(setting)
    "#{setting_name(key)}: #{trim(old)}#{unit(key)} → #{trim(new)}#{unit(key)}"
  end

  # "10.0" as "10".
  defp trim(text), do: String.replace_suffix(text, ".0", "")

  defp group_name("index"), do: "Stock indices"
  defp group_name("fx"), do: "Currencies"
  defp group_name("metal"), do: "Metals"
  defp group_name("commodity"), do: "Commodities"
  defp group_name("bond"), do: "Bonds"
  defp group_name(other), do: other

  # 10.0 as "10", 2.5 as "2.5".
  defp number(value) when is_float(value) and value == trunc(value),
    do: Integer.to_string(trunc(value))

  defp number(value), do: to_string(value)
end
