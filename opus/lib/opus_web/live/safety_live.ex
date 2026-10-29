defmodule OpusWeb.SafetyLive do
  @moduledoc """
  The account safety rules (`Opus.Trading.AccountLimits`): where each one
  stands right now (`Opus.Trading.Safety`), the form that changes them, the
  circuit breaker's exemptions, and the log of every change.

  Tightening a rule saves at once. Loosening one (more room for losses or
  risk, or exempting a strategy from the breaker) asks first. Every save
  pushes the new limits to the engine straight away.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Trading.{AccountLimits, AccountPause, CircuitBreaker, RulesEngine, Safety}

  @breaker_keys [:breaker_losses, :breaker_drawdown_pct, :breaker_window_days]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Safety",
        loaded: false,
        overview: nil,
        values: %{},
        errors: %{},
        pending: nil
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    overview = Safety.overview()

    assign(socket,
      loaded: true,
      overview: overview,
      values: overview && form_values(overview.limits),
      errors: %{},
      pending: nil
    )
  end

  defp form_values(limits),
    do: Map.new(AccountLimits.keys(), &{Atom.to_string(&1), number(Map.fetch!(limits, &1))})

  @impl true
  def handle_event("save", params, %{assigns: %{overview: %{limits: limits}}} = socket) do
    case AccountLimits.diff(limits, params) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :info, "Nothing changed.")}

      {:ok, changes} ->
        if Enum.any?(changes, & &1.loosens?),
          do:
            {:noreply, assign(socket, values: params, errors: %{}, pending: {:limits, changes})},
          else: save(socket, changes)

      {:error, errors} ->
        {:noreply, assign(socket, values: params, errors: errors)}
    end
  end

  def handle_event("exempt", %{"id" => id, "to" => "true"}, socket),
    do: {:noreply, assign(socket, pending: {:exempt, find_breaker(socket, id)})}

  def handle_event("exempt", %{"id" => id, "to" => "false"}, socket),
    do: set_exempt(socket, id, false)

  def handle_event("confirm", _params, %{assigns: %{pending: {:limits, changes}}} = socket),
    do: save(socket, changes)

  def handle_event("confirm", _params, %{assigns: %{pending: {:exempt, row}}} = socket),
    do: set_exempt(socket, row.id, true)

  def handle_event("cancel", _params, socket), do: {:noreply, load(socket)}

  def handle_event("resume", _params, socket) do
    AccountPause.clear()
    RulesEngine.recompute()
    {:noreply, socket |> put_flash(:info, "Trading resumed; rules recomputing.") |> load()}
  end

  defp save(socket, changes) do
    case AccountLimits.save(changes) do
      {:ok, _limits} ->
        RulesEngine.recompute()
        if Enum.any?(changes, &(&1.key in @breaker_keys)), do: CircuitBreaker.recompute()

        {:noreply,
         socket
         |> put_flash(:info, "Saved. The engine gets the new limits now.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
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

  defp find_breaker(socket, id), do: Enum.find(socket.assigns.overview.breakers, &(&1.id == id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex max-w-[960px] flex-col gap-8">
        <header class="flex flex-col gap-1">
          <h1 class="text-[24px] font-semibold tracking-tight"><.t {copy("Account safety")} /></h1>
          <p class="m-0 text-[14px] text-muted">
            <.t {copy(
              "These rules protect the whole account whatever the strategies do. None of them picks trades; they only stop new ones. Nothing switches back on by itself."
            )} />
          </p>
        </header>

        <p :if={@loaded and @overview == nil} class="text-[14px] text-muted">
          <.t {copy("The safety limits aren't set up yet: run the database migrations.")} />
        </p>

        <%= if @overview do %>
          <section
            :if={@overview.pause}
            role="alert"
            class="flex flex-wrap items-center justify-between gap-4 rounded-box border border-error/50 bg-base-200 px-5 py-4"
          >
            <span class="text-[15px] font-semibold text-error">
              <.t {copy("Trading is paused: the account fell %{down} from its peak",
                down: pct(AccountPause.drawdown(@overview.pause.peak_nav, @overview.pause.nav))
              )} />
            </span>
            <button
              type="button"
              phx-click="resume"
              class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] font-medium hover:border-primary"
            >
              <.t {copy("Resume trading")} />
            </button>
          </section>

          <section class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,280px),1fr))] gap-4">
            <.rule_card title={copy("Drawdown pause")}>
              <%= if d = @overview.drawdown do %>
                <.meter
                  used={d.drawdown}
                  limit={@overview.limits.drawdown_pause_pct / 100}
                />
                <p class="m-0 text-[14px]">
                  The account is {pct(d.drawdown)} below its high of {money(d.peak)} (since {date(
                    d.from
                  )}). All trading pauses at {number(@overview.limits.drawdown_pause_pct)}% down.
                </p>
              <% else %>
                <p class="m-0 text-[14px] text-muted">No account snapshot yet.</p>
              <% end %>
            </.rule_card>

            <.rule_card title={copy("Risk budget")}>
              <.meter used={@overview.risk.used} limit={@overview.risk.budget} />
              <p class="m-0 text-[14px]">
                {risk_words(@overview.risk)} New trades are blocked past {pct(@overview.risk.budget)}.
              </p>
            </.rule_card>

            <.rule_card title={copy("Group limit")}>
              <ul class="m-0 flex list-none flex-col gap-1.5 p-0 text-[14px]">
                <li :for={g <- @overview.groups}>
                  <span class="font-medium">{group_name(g.group)}</span>: {g.open} of {@overview.limits.max_open_per_group} open
                  <span class="text-muted">({Enum.join(g.instruments, ", ")})</span>
                </li>
                <li :if={@overview.groups == []} class="text-muted">No strategy is switched on.</li>
              </ul>
              <p class="m-0 text-[13px] text-muted">
                <.t {copy(
                  "Instruments in one group tend to fall together, so only a few may be open at once."
                )} />
              </p>
            </.rule_card>
          </section>

          <section class="flex flex-col gap-3">
            <h2 class="text-[18px] font-semibold tracking-tight"><.t {copy("Circuit breaker")} /></h2>
            <p class="m-0 text-[14px] text-muted">
              Switches a strategy off after {@overview.limits.breaker_losses} losing trades in a row,
              or when its trades lose more than {number(@overview.limits.breaker_drawdown_pct)}% in {@overview.limits.breaker_window_days} days
              (once it has {@overview.min_trades} trades in that time). Counts from its last reset.
            </p>
            <ul class="m-0 flex list-none flex-col border-t border-neutral p-0">
              <li
                :for={b <- @overview.breakers}
                id={"breaker-#{b.id}"}
                class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-5 gap-y-1 border-b border-neutral py-3"
              >
                <div class="flex min-w-0 flex-col gap-0.5">
                  <.link
                    navigate={~p"/strategies/#{b.id}"}
                    class="truncate text-[15px] font-medium hover:text-primary"
                  >
                    {b.name} · {b.instrument}
                  </.link>
                  <span class="text-[13px] text-muted">{breaker_words(b, @overview.limits)}</span>
                </div>
                <button
                  type="button"
                  phx-click="exempt"
                  phx-value-id={b.id}
                  phx-value-to={to_string(!b.circuit_breaker_exempt)}
                  class="min-h-11 rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary"
                >
                  {if b.circuit_breaker_exempt, do: "Use the breaker", else: "Exempt it"}
                </button>
              </li>
              <li :if={@overview.breakers == []} class="py-3 text-[14px] text-muted">
                No strategy is switched on.
              </li>
            </ul>
          </section>

          <section
            :if={@pending}
            role="alert"
            class="flex flex-col gap-3 rounded-box border border-warning/50 bg-base-200 px-5 py-4"
          >
            <span class="text-[15px] font-semibold text-warning">
              <.t {copy("This loosens a safety rule")} />
            </span>
            <ul class="m-0 flex list-disc flex-col gap-1 pl-5 text-[14px]">
              <li :for={line <- pending_lines(@pending)}>{line}</li>
            </ul>
            <p class="m-0 text-[13px] text-muted">
              <.t {copy(
                "Looser rules let bigger losses happen before anything stops them. Make sure that's what you want."
              )} />
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="confirm"
                class="min-h-11 rounded-field bg-warning px-4 text-[14px] font-semibold text-warning-content hover:brightness-110"
              >
                <.t {copy("Yes, loosen it")} />
              </button>
              <button
                type="button"
                phx-click="cancel"
                class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] font-medium hover:border-primary"
              >
                <.t {copy("Cancel")} />
              </button>
            </div>
          </section>

          <section class="flex flex-col gap-3">
            <h2 class="text-[18px] font-semibold tracking-tight">
              <.t {copy("Change the rules")} />
            </h2>
            <form phx-submit="save" class="flex flex-col gap-3">
              <.setting
                :for={key <- AccountLimits.keys()}
                key={key}
                value={@values[Atom.to_string(key)]}
                error={@errors[key]}
              />
              <button
                type="submit"
                class="min-h-11 self-start rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110"
              >
                <.t {copy("Save")} />
              </button>
            </form>
          </section>

          <section class="flex flex-col gap-3">
            <h2 class="text-[18px] font-semibold tracking-tight"><.t {copy("Changes")} /></h2>
            <ul class="m-0 flex list-none flex-col gap-1.5 p-0 text-[14px]">
              <li :for={c <- @overview.changes}>
                <span class="text-muted">{stamp(c.changed_at)}</span> · {change_words(c)}
              </li>
              <li :if={@overview.changes == []} class="text-muted">
                <.t {copy("No changes yet. The rules are the ones set up on Oct 28.")} />
              </li>
            </ul>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  slot :inner_block, required: true
  attr :title, :map, required: true, doc: "copy/1"

  defp rule_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <h2 class="text-[15px] font-semibold"><.t {@title} /></h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :used, :float, required: true
  attr :limit, :float, required: true

  # How much of a limit is used, as a bar that turns amber past two thirds.
  defp meter(assigns) do
    assigns = assign(assigns, share: min(assigns.used / max(assigns.limit, 1.0e-9), 1.0))

    ~H"""
    <div
      role="meter"
      aria-valuemin="0"
      aria-valuemax={@limit}
      aria-valuenow={@used}
      class="h-2 w-full overflow-hidden rounded-full bg-base-300"
    >
      <div
        class={["h-full rounded-full", if(@share >= 2 / 3, do: "bg-warning", else: "bg-success")]}
        style={"width: #{Float.round(@share * 100, 1)}%"}
      />
    </div>
    """
  end

  attr :key, :atom, required: true
  attr :value, :string, default: nil
  attr :error, :string, default: nil

  defp setting(assigns) do
    {min, max} = AccountLimits.range(assigns.key)
    {before, unit} = setting_words(assigns.key)
    assigns = assign(assigns, min: min, max: max, before: before, unit: unit)

    ~H"""
    <label class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[14px]">
      <span class="min-w-[18rem]">{@before}</span>
      <input
        type="number"
        name={Atom.to_string(@key)}
        value={@value}
        min={@min}
        max={@max}
        step="any"
        aria-invalid={to_string(@error != nil)}
        class="min-h-11 w-24 rounded-field border border-base-300 bg-base-100 px-3 text-right"
      />
      <span class="text-muted">{@unit}</span>
      <span :if={@error} class="basis-full text-[13px] text-error">{@error}</span>
    </label>
    """
  end

  defp setting_words(:drawdown_pause_pct),
    do: {"Pause all trading when the account falls", "% from its high"}

  defp setting_words(:risk_budget_pct), do: {"Most of the account at risk at once", "%"}
  defp setting_words(:max_open_per_group), do: {"Most open trades in one group", "trades"}
  defp setting_words(:breaker_losses), do: {"Switch a strategy off after", "losses in a row"}
  defp setting_words(:breaker_drawdown_pct), do: {"…or when its trades lose more than", "%"}
  defp setting_words(:breaker_window_days), do: {"…within", "days"}

  defp setting_name(:drawdown_pause_pct), do: "Drawdown pause"
  defp setting_name(:risk_budget_pct), do: "Risk budget"
  defp setting_name(:max_open_per_group), do: "Most open per group"
  defp setting_name(:breaker_losses), do: "Breaker: losses in a row"
  defp setting_name(:breaker_drawdown_pct), do: "Breaker: loss over the window"
  defp setting_name(:breaker_window_days), do: "Breaker: window"

  defp unit(key) when key in [:drawdown_pause_pct, :risk_budget_pct, :breaker_drawdown_pct],
    do: "%"

  defp unit(:breaker_window_days), do: " days"
  defp unit(_key), do: ""

  defp pending_lines({:limits, changes}) do
    for c <- changes do
      marker = if c.loosens?, do: " (looser)", else: ""

      "#{setting_name(c.key)}: #{number(c.old)}#{unit(c.key)} → #{number(c.new)}#{unit(c.key)}#{marker}"
    end
  end

  defp pending_lines({:exempt, row}),
    do: [
      "#{row.name} on #{row.instrument} keeps trading through losing streaks and losses: " <>
        "the circuit breaker won't switch it off."
    ]

  defp change_words(%{setting: "circuit_breaker_exempt", subject: subject, new_value: "true"}),
    do: "#{subject}: exempt from the circuit breaker"

  defp change_words(%{setting: "circuit_breaker_exempt", subject: subject}),
    do: "#{subject}: back under the circuit breaker"

  defp change_words(%{setting: setting, old_value: old, new_value: new}) do
    key = String.to_existing_atom(setting)
    "#{setting_name(key)}: #{old}#{unit(key)} → #{new}#{unit(key)}"
  end

  defp risk_words(%{trades: 0}), do: "No trade is open, so none of the budget is used."

  defp risk_words(%{trades: n, used: used}),
    do:
      "#{n} open #{if n == 1, do: "trade risks", else: "trades risk"} #{pct(used)} of the account."

  defp breaker_words(%{suspension: %{trigger_detail: detail}}, _limits),
    do: "Switched off: #{detail}. Reset it on its page."

  defp breaker_words(%{circuit_breaker_exempt: true}, _limits),
    do: "Exempt: the breaker leaves it alone."

  defp breaker_words(b, limits) do
    streak =
      case b.streak do
        0 -> "Last trade wasn't a loss"
        n -> "#{n} of #{limits.breaker_losses} losses in a row"
      end

    window =
      "#{signed_pct(b.window_sum)} over #{limits.breaker_window_days} days " <>
        "(switches off below −#{number(limits.breaker_drawdown_pct)}%, #{b.window_trades} trades)"

    "#{streak} · #{window}"
  end

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
