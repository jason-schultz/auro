defmodule OpusWeb.StrategyBuilderLive do
  @moduledoc """
  Build a strategy, or change one: pick signal blocks and their settings,
  say when to buy, sell short and close each from those blocks' rules, set
  the stop and hold limit, and watch where the rules would have bought and
  sold on an instrument (the engine's signal preview, refreshed as the
  form changes).

  `/strategies/new` starts empty. `/strategies/recipes/:id/edit` opens a
  recipe; `?copy=1` opens it as a copy. A recipe that's trading somewhere
  opens locked (read-only). Unlocking asks how: edit a copy (the original
  keeps trading) or switch every instrument off first (refused while one
  holds an open trade). Saving goes through `Opus.Trading.Recipes`; a new
  recipe or copy can go straight to the tests on the preview instrument,
  and an in-place edit re-runs the tests on every instrument it's on.

  The engine checks the rules before anything is saved: a save needs a
  preview that worked.
  """
  use OpusWeb, :live_view

  import OpusWeb.SignalChart, only: [signal_chart: 1]
  import OpusWeb.StrategyParts, only: [locked_words: 1, runs_list: 1]

  alias Opus.Auro.Client

  alias Opus.Trading.{
    Blocks,
    Granularity,
    RecipeForm,
    Recipes,
    Strategies,
    StrategyResults,
    StrategyWords
  }

  alias OpusWeb.WholeHistory

  # How long the form must sit still before the whole-history run starts: a
  # 5-minute strategy takes seconds, too long to repeat on every keystroke.
  @report_after_ms 1_200

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        recipe: nil,
        runs: [],
        assignments: [],
        mode: :new,
        lock: :open,
        form: RecipeForm.new(),
        too_complex: false,
        instrument: nil,
        instruments: [],
        chart: nil,
        preview_error: nil,
        untestable: nil,
        focus: nil,
        report_ref: nil,
        page_title: "New strategy"
      )
      |> WholeHistory.init()

    {:ok, socket |> open(socket.assigns.live_action, params) |> refresh_instruments()}
  end

  defp open(socket, :new, _params), do: socket

  defp open(socket, :edit, %{"recipe_id" => id} = params) do
    case Recipes.get(id) do
      nil ->
        socket |> put_flash(:error, "No such strategy.") |> push_navigate(to: ~p"/strategies")

      recipe ->
        assignments = Recipes.assignments(recipe.id)
        copy? = params["copy"] == "1"

        {form, too_complex} =
          case RecipeForm.from_definition(
                 recipe.definition,
                 recipe.name,
                 recipe.granularity,
                 recipe.notes
               ) do
            {:ok, form} -> {form, false}
            {:error, :too_complex} -> {RecipeForm.new(), true}
          end

        runs = StrategyResults.for_recipe(recipe.definition)

        socket
        |> assign(
          recipe: recipe,
          assignments: assignments,
          runs: runs,
          form: if(copy?, do: Map.update!(form, "name", &"#{&1} (copy)"), else: form),
          too_complex: too_complex,
          mode: if(copy?, do: :copy, else: :edit),
          lock: if(not copy? and Recipes.locked_by(assignments) != [], do: :locked, else: :open),
          instrument: first_instrument(assignments, runs),
          page_title: recipe.name
        )
    end
  end

  # Where to preview first: an instrument it runs on, else the one it was
  # last tested on (the preview picks a default when there's neither).
  defp first_instrument([first | _], _runs), do: first.instrument
  defp first_instrument([], []), do: nil
  defp first_instrument([], runs), do: Enum.max_by(runs, & &1.ran_at, DateTime).instrument

  # Instruments with recent bars at the form's timeframe, for the preview.
  defp refresh_instruments(socket) do
    instruments = Strategies.preview_instruments(socket.assigns.form["granularity"])

    instrument =
      cond do
        socket.assigns.instrument in instruments -> socket.assigns.instrument
        "SPX500_USD" in instruments -> "SPX500_USD"
        true -> List.first(instruments)
      end

    socket |> assign(instruments: instruments, instrument: instrument) |> preview()
  end

  defp preview(%{assigns: %{instrument: nil}} = socket),
    do:
      assign(socket,
        untestable: nil,
        chart: nil,
        preview_error: "No instrument has recent bars at this timeframe.",
        report: {:ok, nil},
        report_ref: nil
      )

  defp preview(socket) do
    %{instrument: instrument, form: %{"granularity" => granularity}} = socket.assigns
    socket = assign(socket, untestable: untestable(instrument, granularity))

    if connected?(socket) do
      definition = definition(socket.assigns)

      socket
      |> WholeHistory.assign_axes(definition)
      |> cancel_async(:fragility, :form_changed)
      |> assign(fragility: :idle)
      |> schedule_report()
      |> start_async(:preview, fn ->
        Strategies.preview(definition, instrument, granularity, nil)
      end)
    else
      socket
    end
  end

  # The rules as the form has them now.
  defp definition(%{form: form, recipe: recipe}),
    do: RecipeForm.to_definition(form, (recipe && recipe.definition) || %{})

  # Run the strategy over its whole history once the form sits still; an
  # instrument without history before the holdout has nothing to run on.
  defp schedule_report(%{assigns: %{untestable: words}} = socket) when is_binary(words),
    do: assign(socket, report: {:ok, nil}, report_ref: nil)

  defp schedule_report(socket) do
    ref = make_ref()
    Process.send_after(self(), {:report, ref}, @report_after_ms)
    assign(socket, report: :loading, report_ref: ref)
  end

  # Why the tests can't run on this instrument, in words, or nil.
  defp untestable(instrument, granularity) do
    case Recipes.testable(instrument, granularity) do
      :ok ->
        nil

      {:error, {:no_history, first, holdout}} ->
        since = if first, do: "only since #{Calendar.strftime(first, "%b %-d, %Y")}", else: "none"

        "#{instrument} has #{StrategyWords.timeframe(granularity)} #{since}. The tests only use " <>
          "history from before #{Calendar.strftime(holdout, "%b %-d, %Y")} (everything after is " <>
          "kept aside for the holdout), so it can be previewed here but not tested. Pick an " <>
          "instrument with longer history, or other bars."
    end
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, chart}}, socket),
    do: {:noreply, assign(socket, chart: chart, preview_error: nil, focus: nil)}

  def handle_async(:preview, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, chart: nil, preview_error: Client.describe_error(reason))}

  def handle_async(:preview, {:exit, _}, socket),
    do: {:noreply, assign(socket, chart: nil, preview_error: "The preview didn't finish.")}

  # A check cancelled because the form changed: its grid would be stale.
  def handle_async(:fragility, {:exit, :form_changed}, socket), do: {:noreply, socket}

  def handle_async(name, result, socket) when name in [:report, :fragility],
    do: {:noreply, WholeHistory.put_result(socket, name, result)}

  @impl true
  def handle_info({:report, ref}, %{assigns: %{report_ref: ref}} = socket) do
    %{instrument: instrument, form: %{"granularity" => granularity}} = socket.assigns
    definition = definition(socket.assigns)

    {:noreply,
     start_async(socket, :report, fn ->
       Strategies.report(definition, instrument, granularity, nil)
     end)}
  end

  # The form changed again before this one was due.
  def handle_info({:report, _stale}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change", %{"form" => params} = all, socket) do
    # A rule picker ("Add a condition…") sends its choice under `add`.
    form =
      for {slot, ref} <- all["add"] || %{},
          slot in RecipeForm.rules() and ref != "",
          reduce: merge(socket.assigns.form, params) do
        form -> RecipeForm.add_ref(form, slot, ref)
      end

    timeframe_changed? = form["granularity"] != socket.assigns.form["granularity"]

    socket =
      socket
      |> assign(form: form, instrument: all["instrument"] || socket.assigns.instrument)

    {:noreply, if(timeframe_changed?, do: refresh_instruments(socket), else: preview(socket))}
  end

  # Locked, the form's fields are disabled and only the preview's
  # instrument comes back.
  def handle_event("change", params, socket),
    do:
      {:noreply,
       socket
       |> assign(instrument: params["instrument"] || socket.assigns.instrument)
       |> preview()}

  def handle_event("add_block", %{"type" => type}, socket) do
    if Blocks.get(type),
      do: {:noreply, socket |> update(:form, &RecipeForm.add_component(&1, type)) |> preview()},
      else: {:noreply, socket}
  end

  def handle_event("use_template", %{"id" => id}, socket) do
    case RecipeForm.template(id) do
      nil -> {:noreply, socket}
      form -> {:noreply, socket |> assign(form: form) |> refresh_instruments()}
    end
  end

  def handle_event("remove_block", %{"key" => key}, socket),
    do: {:noreply, socket |> update(:form, &RecipeForm.remove_component(&1, key)) |> preview()}

  def handle_event("remove_ref", %{"slot" => slot, "ref" => ref}, socket),
    do: {:noreply, socket |> update(:form, &RecipeForm.remove_ref(&1, slot, ref)) |> preview()}

  def handle_event("pick_trade", %{"trade" => trade}, socket),
    do: {:noreply, assign(socket, focus: String.to_integer(trade))}

  def handle_event("fragility_axes", params, socket),
    do: {:noreply, WholeHistory.pick_axes(socket, params)}

  def handle_event("check_fragility", _params, socket) do
    %{instrument: instrument, form: %{"granularity" => granularity}} = socket.assigns
    definition = definition(socket.assigns)
    {x, y} = WholeHistory.chosen_axes(socket.assigns)

    {:noreply,
     socket
     |> assign(fragility: :running)
     |> start_async(:fragility, fn ->
       Strategies.fragility(definition, instrument, granularity, nil, x, y)
     end)}
  end

  def handle_event("delete", _params, socket) do
    case Recipes.delete(socket.assigns.recipe) do
      {:ok, recipe} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{recipe.name}.")
         |> push_navigate(to: ~p"/strategies")}

      {:error, :locked} ->
        {:noreply,
         put_flash(socket, :error, "It's trading, so it can't be deleted. Switch it off first.")}

      {:error, {:engine, failures}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't remove it from " <>
             Enum.map_join(failures, ", ", fn {i, r} -> "#{i} (#{describe(r)})" end) <>
             ", so it wasn't deleted."
         )}
    end
  end

  def handle_event("ask_unlock", _params, socket),
    do: {:noreply, assign(socket, lock: :confirming)}

  def handle_event("cancel_unlock", _params, socket),
    do: {:noreply, assign(socket, lock: :locked)}

  def handle_event("unlock_copy", _params, socket) do
    {:noreply,
     socket
     |> assign(mode: :copy, lock: :open)
     |> update(:form, &Map.update!(&1, "name", fn name -> "#{name} (copy)" end))}
  end

  def handle_event("unlock_off", _params, %{assigns: %{assignments: assignments}} = socket) do
    case Enum.filter(assignments, &(&1.open_trades > 0)) do
      [] ->
        case Recipes.switch_off(assignments) do
          :ok ->
            {:noreply,
             socket
             |> assign(assignments: Recipes.assignments(socket.assigns.recipe.id), lock: :open)
             |> put_flash(
               :info,
               "Switched off. It won't open new trades until you switch it back on."
             )}

          {:error, failures} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Couldn't switch off " <>
                 Enum.map_join(failures, ", ", fn {i, r} -> "#{i} (#{describe(r)})" end) <> "."
             )}
        end

      open ->
        {:noreply,
         socket
         |> assign(lock: :locked)
         |> put_flash(
           :error,
           "#{Enum.map_join(open, ", ", & &1.instrument)} has an open trade. It can be edited once that closes, or edit a copy now."
         )}
    end
  end

  def handle_event("save", %{"then" => then} = params, socket) do
    socket =
      if params["form"],
        do: update(socket, :form, &merge(&1, params["form"])),
        else: socket

    %{form: form, recipe: recipe, mode: mode, chart: chart} = socket.assigns

    cond do
      String.trim(form["name"]) == "" ->
        {:noreply, put_flash(socket, :error, "Give it a name first.")}

      is_nil(chart) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The engine checks the rules before saving, and the preview hasn't worked: " <>
             (socket.assigns.preview_error || "it's still loading.")
         )}

      true ->
        attrs = %{
          name: String.trim(form["name"]),
          granularity: form["granularity"],
          notes: blank_to_nil(form["notes"]),
          definition: RecipeForm.to_definition(form, (recipe && recipe.definition) || %{})
        }

        save(socket, mode, then, attrs)
    end
  end

  defp save(socket, :edit, _then, attrs) do
    case Recipes.update(socket.assigns.recipe, attrs) do
      {:ok, saved} ->
        retested = Enum.map(socket.assigns.assignments, & &1.instrument)
        Enum.each(retested, &Recipes.run_tests(saved, &1))

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Saved. The tests are running again on #{Enum.join(retested, ", ")}; switch them back on when they pass."
         )
         |> push_navigate(to: ~p"/strategies")}

      {:error, :locked} ->
        {:noreply,
         put_flash(socket, :error, "It's trading again, so it's locked. Edit a copy instead.")}

      {:error, :timeframe_in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "It runs on instruments at its current timeframe. Save a copy to change the timeframe."
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, errors(changeset))}
    end
  end

  defp save(socket, _new_or_copy, then, attrs) do
    with {:ok, saved} <- Recipes.create(attrs),
         :ok <- maybe_test(saved, then, socket.assigns.instrument) do
      message =
        if then == "test",
          do:
            "Saved. Testing it on #{socket.assigns.instrument}: backtest first; results appear on its card.",
          else: "Saved as a draft."

      {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/strategies")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, errors(changeset))}

      {:error, {:no_history, _first, _holdout}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Saved as a draft. " <>
             untestable(socket.assigns.instrument, socket.assigns.form["granularity"])
         )
         |> push_navigate(to: ~p"/strategies")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Saved, but the tests didn't start: #{inspect(reason)}")}
    end
  end

  defp maybe_test(recipe, "test", instrument) do
    case Recipes.run_tests(recipe, instrument) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_test(_recipe, _draft, _instrument), do: :ok

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} ->
      "#{if field == :definition, do: "The rules", else: String.capitalize(to_string(field))} #{Enum.join(msgs, ", ")}"
    end)
    |> Kernel.<>(".")
  end

  defp describe(reason), do: Client.describe_error(reason)

  defp delete_scope([]), do: ""

  defp delete_scope(assignments),
    do: " and remove it from " <> Enum.map_join(assignments, ", ", & &1.instrument)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  # The browser sends the whole form; rules' checkbox lists arrive with a
  # blank placeholder so an emptied list still comes back.
  defp merge(form, params) do
    components =
      Enum.map(form["components"], fn c ->
        case get_in(params, ["components", c["key"]]) do
          nil -> c
          sent -> Map.update!(c, "params", &Map.merge(&1, sent))
        end
      end)

    rules =
      Map.new(RecipeForm.rules(), fn slot ->
        sent = get_in(params, ["rules", slot]) || %{}

        {slot,
         %{
           "mode" => sent["mode"] || form["rules"][slot]["mode"],
           "refs" => Enum.reject(sent["refs"] || [], &(&1 == ""))
         }}
      end)

    stop =
      Map.merge(form["stop"], params["stop"] || %{}, fn
        "params", old, new -> Map.merge(old, new)
        _key, _old, new -> new
      end)

    form
    |> Map.merge(Map.take(params, ~w(name granularity notes hold)))
    |> Map.merge(%{"components" => components, "rules" => rules, "stop" => stop})
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        locked: assigns.lock != :open,
        choices: RecipeForm.choices(assigns.form),
        groups: RecipeForm.grouped_choices(assigns.form),
        words: assigns.form |> RecipeForm.choices() |> Map.new(),
        own_stop: Enum.filter(assigns.form["components"], &(&1["type"] in RecipeForm.own_stop())),
        definition:
          RecipeForm.to_definition(
            assigns.form,
            (assigns.recipe && assigns.recipe.definition) || %{}
          )
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <div class="flex flex-col gap-2">
          <.link
            navigate={~p"/strategies"}
            class="self-start text-[13px] text-muted hover:text-base-content"
          >
            ← <.t {copy("Strategies")} />
          </.link>
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <h1 class="text-[24px] font-semibold tracking-tight">
              <%= case @mode do %>
                <% :new -> %>
                  <.t {copy("New strategy")} />
                <% :copy -> %>
                  <.t {copy("Copy of %{name}", name: @recipe.name)} />
                <% :edit -> %>
                  {@recipe.name}
              <% end %>
            </h1>
            <button
              :if={@mode == :edit}
              type="button"
              phx-click="delete"
              disabled={@lock != :open}
              title={if @lock != :open, do: "It's trading. Switch it off before deleting it."}
              data-confirm={"Delete #{@recipe.name}#{delete_scope(@assignments)}? This can't be undone. Its test history is kept."}
              class="min-h-11 px-1 text-[14px] font-medium text-error disabled:cursor-not-allowed disabled:text-muted"
            >
              <.t {copy("Delete")} />
            </button>
          </div>
          <p class="text-[14px] text-muted">
            <.t {copy("Build the signal from blocks, say when to act on it, and see where it would have bought and sold.")} />
          </p>
        </div>

        <section
          :if={@lock == :locked}
          aria-live="polite"
          class="flex flex-wrap items-center justify-between gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex min-w-0 flex-[1_1_420px] items-start gap-3">
            <.icon name="hero-lock-closed" class="mt-0.5 size-5 shrink-0" />
            <p class="m-0 text-[14px]">
              <strong><.t {copy("Locked.")} /></strong>
              {locked_words(Recipes.locked_by(@assignments))}
              <.t {copy("You can look and preview, but not change anything.")} />
            </p>
          </div>
          <button
            type="button"
            phx-click="ask_unlock"
            class="min-h-11 rounded-field bg-base-content px-4 text-[14px] font-semibold text-base-100 hover:brightness-110"
          >
            <.t {copy("Unlock to edit")} />
          </button>
        </section>

        <section
          :if={@lock == :confirming}
          role="dialog"
          aria-labelledby="unlock-h"
          class="flex flex-col gap-4 rounded-box border border-warning bg-base-200 px-5 py-5"
        >
          <h2 id="unlock-h" class="text-[17px] font-semibold">
            <.t {copy("How do you want to change it?")} />
          </h2>
          <p class="m-0 text-[14px] text-muted">
            <.t {copy("Changing these rules would change a live strategy mid-trade. Pick one:")} />
          </p>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,300px),1fr))] gap-3">
            <button
              type="button"
              phx-click="unlock_copy"
              class="flex min-h-11 flex-col items-start gap-1 rounded-field border border-primary bg-primary/10 px-4 py-4 text-left"
            >
              <strong>
                <.t {copy("Edit a copy")} />
                <span class="font-semibold text-primary">(recommended)</span>
              </strong>
              <span class="text-[14px] text-muted">
                <.t {copy("The original keeps trading untouched. The copy goes through the tests, then you choose where it runs.")} />
              </span>
            </button>
            <button
              type="button"
              phx-click="unlock_off"
              class="flex min-h-11 flex-col items-start gap-1 rounded-field border border-base-300 bg-base-100 px-4 py-4 text-left"
            >
              <strong><.t {copy("Switch it off everywhere, then edit")} /></strong>
              <span class="text-[14px] text-muted">
                <.t {copy("No new trades until it passes the tests again and you switch it back on. Not possible while a trade is open.")} />
              </span>
            </button>
          </div>
          <button
            type="button"
            phx-click="cancel_unlock"
            class="min-h-11 self-start px-1 text-[14px] text-muted hover:text-base-content"
          >
            <.t {copy("Keep it locked")} />
          </button>
        </section>

        <p
          :if={@too_complex}
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          This strategy's rules nest deeper than the builder handles, so it can't be edited here.
        </p>

        <section
          :if={@mode == :new and @form["components"] == []}
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <h2 class="text-[15px] font-semibold">
            <.t {copy("Start from an example")} />
          </h2>
          <p class="m-0 text-[14px] text-muted">
            Each one is a complete strategy you can open, look at in the preview and change.
            Or start from nothing below.
          </p>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,240px),1fr))] gap-3">
            <button
              :for={t <- RecipeForm.templates()}
              type="button"
              phx-click="use_template"
              phx-value-id={t.id}
              class="flex min-h-11 flex-col items-start gap-1 rounded-field border border-base-300 bg-base-100 px-4 py-3 text-left hover:border-primary"
            >
              <span class="text-[14px] font-semibold">{t.name}</span>
              <span class="text-[13px] text-muted">{t.description}</span>
            </button>
          </div>
        </section>

        <form
          :if={!@too_complex}
          id="builder"
          phx-change="change"
          phx-submit="save"
          class="flex flex-col gap-6 lg:grid lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:items-start"
        >
          <fieldset
            disabled={@locked}
            class="m-0 flex min-w-0 flex-col gap-4 border-0 p-0"
          >
            <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <h2 class="text-[15px] font-semibold">
                <span class="text-muted">1 ·</span> <.t {copy("What it is")} />
              </h2>
              <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
                <.field label="Name">
                  <input
                    type="text"
                    name="form[name]"
                    value={@form["name"]}
                    required
                    phx-debounce="400"
                    class="input w-full"
                  />
                </.field>
                <.field label="Bars">
                  <select
                    name="form[granularity]"
                    disabled={@mode == :edit && @assignments != []}
                    class="select w-full"
                  >
                    <option
                      :for={g <- Granularity.all()}
                      value={g}
                      selected={g == @form["granularity"]}
                    >
                      {StrategyWords.timeframe(g)}
                    </option>
                  </select>
                </.field>
              </div>
              <.field label="What it's for (optional)">
                <input
                  type="text"
                  name="form[notes]"
                  value={@form["notes"]}
                  phx-debounce="400"
                  placeholder="Buys a sharp dip in an uptrend and sells the bounce"
                  class="input w-full"
                />
              </.field>
            </section>

            <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <h2 class="text-[15px] font-semibold">
                <span class="text-muted">2 ·</span>
                <.t {copy("Signals it watches")} />
              </h2>
              <p :if={@form["components"] == []} class="m-0 text-[14px] text-muted">
                A block watches one thing about the price and answers simple yes/no questions about it,
                like "is RSI below 20?". Pick one below; its questions become the rules in step 3.
              </p>
              <div
                :for={c <- @form["components"]}
                :if={block = Blocks.get(c["type"])}
                class="flex flex-col gap-3 rounded-field border border-base-300 bg-base-100 px-4 py-3"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="flex flex-col gap-1">
                    <span class="flex flex-wrap items-baseline gap-x-2">
                      <strong>{block.name}</strong>
                      <span class="text-[12px] text-muted">{block.group}</span>
                    </span>
                    <span class="text-[13px] text-muted">{block.watches}</span>
                  </div>
                  <button
                    type="button"
                    phx-click="remove_block"
                    phx-value-key={c["key"]}
                    aria-label={"Remove #{block.name}"}
                    class="min-h-9 min-w-9 shrink-0 rounded-field text-muted hover:text-error"
                  >
                    <.icon name="hero-x-mark-mini" class="size-4" />
                  </button>
                </div>
                <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
                  <.field :for={p <- block.params} label={p.label} help={p.help}>
                    <%= case p.kind do %>
                      <% {:select, options} -> %>
                        <select
                          name={"form[components][#{c["key"]}][#{p.key}]"}
                          class="select w-full"
                        >
                          <option
                            :for={{label, value} <- options}
                            value={value}
                            selected={value == c["params"][p.key]}
                          >
                            {label}
                          </option>
                        </select>
                      <% kind -> %>
                        <input
                          type="number"
                          step={if kind == :int, do: "1", else: "any"}
                          name={"form[components][#{c["key"]}][#{p.key}]"}
                          value={c["params"][p.key]}
                          phx-debounce="500"
                          class="input w-full"
                        />
                    <% end %>
                  </.field>
                </div>
              </div>
              <details
                open={@form["components"] == []}
                class="rounded-field border border-dashed border-base-300 px-4 py-2"
              >
                <summary class="min-h-9 cursor-pointer py-1.5 text-[14px] font-medium text-primary">
                  + <.t {copy("Add a block")} />
                </summary>
                <div class="flex flex-col gap-4 pb-2 pt-2">
                  <div
                    :for={{group, question, blocks} <- Blocks.by_group()}
                    class="flex flex-col gap-1.5"
                  >
                    <span class="text-[13px]">
                      <strong>{group}</strong> <span class="text-muted">· {question}</span>
                    </span>
                    <button
                      :for={b <- blocks}
                      type="button"
                      phx-click="add_block"
                      phx-value-type={b.type}
                      class="flex min-h-11 flex-col items-start gap-0.5 rounded-field border border-base-300 bg-base-100 px-3 py-2 text-left hover:border-primary"
                    >
                      <span class="text-[14px] font-medium">+ {b.name}</span>
                      <span class="text-[12px] text-muted">{b.watches}</span>
                    </button>
                  </div>
                </div>
              </details>
            </section>

            <section class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <h2 class="text-[15px] font-semibold">
                <span class="text-muted">3 ·</span> <.t {copy("When to act")} />
              </h2>
              <p :if={@choices == []} class="m-0 text-[14px] text-muted">
                The rules to pick from appear once there's a block in step 2.
              </p>
              <.rule_slot
                :for={
                  {slot, label, color} <- [
                    {"entry_long", "Buy when", "text-info"},
                    {"exit_long", "Close the buy when", "text-warning"},
                    {"entry_short", "Sell short when", "text-warning"},
                    {"exit_short", "Close the short when", "text-info"}
                  ]
                }
                :if={@choices != []}
                slot={slot}
                label={label}
                color={color}
                rule={@form["rules"][slot]}
                groups={@groups}
                words={@words}
              />
              <p :if={@choices != []} class="m-0 text-[13px] text-muted">
                Leave "Sell short when" empty and it only buys. A trade also closes at the stop
                or the hold limit in step 4.
              </p>
            </section>

            <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <h2 class="text-[15px] font-semibold">
                <span class="text-muted">4 ·</span> <.t {copy("Protect it")} />
              </h2>
              <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
                <.field label="Stop">
                  <select
                    name="form[stop][type]"
                    class="select w-full"
                  >
                    <option value="AtrMultiple" selected={@form["stop"]["type"] == "AtrMultiple"}>
                      Average range × (ATR)
                    </option>
                    <option value="FixedPct" selected={@form["stop"]["type"] == "FixedPct"}>
                      Fixed %
                    </option>
                    <option
                      :if={@own_stop != []}
                      value="FromComponent"
                      selected={@form["stop"]["type"] == "FromComponent"}
                    >
                      Set by a block
                    </option>
                  </select>
                </.field>
                <%= case @form["stop"]["type"] do %>
                  <% "AtrMultiple" -> %>
                    <.field label="Times the range">
                      <input
                        type="number"
                        step="any"
                        name="form[stop][params][k]"
                        value={@form["stop"]["params"]["k"] || "3"}
                        phx-debounce="500"
                        class="input w-full"
                      />
                    </.field>
                    <.field label="Range over (bars)">
                      <input
                        type="number"
                        step="1"
                        name="form[stop][params][period]"
                        value={@form["stop"]["params"]["period"] || "14"}
                        phx-debounce="500"
                        class="input w-full"
                      />
                    </.field>
                  <% "FixedPct" -> %>
                    <.field label="% from the entry">
                      <input
                        type="number"
                        step="any"
                        name="form[stop][params][pct]"
                        value={@form["stop"]["params"]["pct"] || "2"}
                        phx-debounce="500"
                        class="input w-full"
                      />
                    </.field>
                  <% "FromComponent" -> %>
                    <.field label="Which block">
                      <select
                        name="form[stop][params][component]"
                        class="select w-full"
                      >
                        <option
                          :for={c <- @own_stop}
                          value={c["key"]}
                          selected={c["key"] == @form["stop"]["params"]["component"]}
                        >
                          {Blocks.get(c["type"]).name}
                        </option>
                      </select>
                    </.field>
                  <% _ -> %>
                <% end %>
                <.field label="Close after (bars, optional)">
                  <input
                    type="number"
                    step="1"
                    min="1"
                    name="form[hold]"
                    value={@form["hold"]}
                    phx-debounce="500"
                    class="input w-full"
                  />
                </.field>
              </div>
              <p class="m-0 text-[13px] text-muted">
                How much each trade risks is set per instrument when it's switched on, not here.
              </p>
            </section>
          </fieldset>

          <div class="order-first flex min-w-0 flex-col gap-4 lg:sticky lg:top-24 lg:order-none lg:max-h-[calc(100vh-7rem)] lg:overflow-y-auto">
            <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h2 class="text-[15px] font-semibold"><.t {copy("Preview")} /></h2>
                <label class="inline-flex items-center gap-2 text-[13px] text-muted">
                  On
                  <select
                    name="instrument"
                    class="select select-sm w-auto"
                  >
                    <option :for={i <- @instruments} value={i} selected={i == @instrument}>
                      {i}
                    </option>
                  </select>
                </label>
              </div>
              <%= if @chart do %>
                <.signal_chart
                  chart={@chart}
                  definition={@definition}
                  granularity={@form["granularity"]}
                  focus={@focus}
                  label={"Preview of buy and sell signals on #{@instrument}"}
                />
              <% else %>
                <p class="m-0 text-[14px] text-muted">
                  {@preview_error || "Loading the preview…"}
                </p>
              <% end %>
              <p class="m-0 text-[12px] text-muted">
                Runs the rules through the same engine code as the backtest, on the last 120 bars.
                The list only has instruments with {StrategyWords.timeframe(@form["granularity"])} stored, so it changes with the bars you pick.
              </p>
            </section>

            <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
              <h2 class="text-[15px] font-semibold">
                <.t {copy("What happens when you save")} />
              </h2>
              <ol class="m-0 flex list-decimal flex-col gap-1 pl-5 text-[14px] text-muted">
                <%= if @mode == :edit do %>
                  <li>
                    The new rules apply to every instrument it's on: {Enum.map_join(
                      @assignments,
                      ", ",
                      & &1.instrument
                    )}.
                  </li>
                  <li>The tests run again on each of them.</li>
                  <li>They stay off until you switch them back on.</li>
                <% else %>
                  <li>
                    It's tested on {@instrument}: backtest, walk-forward, Monte Carlo, then the holdout (a one-time look at data kept aside).
                  </li>
                  <li>If it passes, it's added to {@instrument}, switched off.</li>
                  <li>Nothing trades until you switch it on.</li>
                <% end %>
              </ol>
              <p
                :if={@untestable && @mode != :edit}
                role="alert"
                class="m-0 rounded-field border border-warning/40 bg-base-100 px-3 py-2 text-[13px]"
              >
                {@untestable}
              </p>
              <div class="flex flex-wrap gap-2">
                <button
                  type="submit"
                  name="then"
                  value="test"
                  disabled={@locked or (@untestable != nil and @mode != :edit)}
                  class="min-h-11 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <%= if @mode == :edit do %>
                    <.t {copy("Save changes")} />
                  <% else %>
                    <.t {copy("Save and run the tests")} />
                  <% end %>
                </button>
                <button
                  :if={@mode != :edit}
                  type="submit"
                  name="then"
                  value="draft"
                  disabled={@locked}
                  class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] hover:border-primary disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <.t {copy("Save as a draft")} />
                </button>
              </div>
            </section>
          </div>
        </form>

        <section
          :if={@instrument}
          aria-label="Whole history"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-col gap-1">
            <h2 class="text-[15px] font-semibold">
              <.t {copy("Over its whole history on %{instrument}", instrument: @instrument)} />
            </h2>
            <p class="m-0 text-[13px] text-muted">
              The preview shows the last 120 bars; this runs the rules as they are now over every bar
              the tests use, before the holdout. It reruns a moment after you stop changing things.
            </p>
          </div>
          <WholeHistory.panel
            report={@report}
            fragility={@fragility}
            axes={@axes}
            fx={@fx}
            fy={@fy}
            instrument={@instrument}
            granularity={@form["granularity"]}
          />
        </section>

        <section
          :if={@runs != []}
          id="tests"
          class="flex scroll-mt-24 flex-col gap-2 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <h2 class="text-[15px] font-semibold"><.t {copy("Test results")} /></h2>
          <.runs_list runs={@runs} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :help, :string, default: nil
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <label class="flex flex-col gap-1 text-[13px] text-muted">
      {@label}
      {render_slot(@inner_block)}
      <span :if={@help} class="text-[12px] leading-snug">{@help}</span>
    </label>
    """
  end

  attr :slot, :string, required: true
  attr :label, :string, required: true
  attr :color, :string, required: true
  attr :rule, :map, required: true
  attr :groups, :list, required: true, doc: "RecipeForm.grouped_choices/1"
  attr :words, :map, required: true, doc: "ref => words"

  defp rule_slot(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 border-b border-neutral pb-4 last:border-b-0 last:pb-0">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class={["text-[14px] font-semibold", @color]}>{@label}</span>
        <div :if={length(@rule["refs"]) > 1} class="flex items-center gap-3 text-[13px] text-muted">
          <label class="inline-flex min-h-9 items-center gap-1.5">
            <input
              type="radio"
              class="radio radio-xs"
              name={"form[rules][#{@slot}][mode]"}
              value="and"
              checked={@rule["mode"] != "or"}
            /> all of these
          </label>
          <label class="inline-flex min-h-9 items-center gap-1.5">
            <input
              type="radio"
              class="radio radio-xs"
              name={"form[rules][#{@slot}][mode]"}
              value="or"
              checked={@rule["mode"] == "or"}
            /> any of these
          </label>
        </div>
        <input
          :if={length(@rule["refs"]) <= 1}
          type="hidden"
          name={"form[rules][#{@slot}][mode]"}
          value={@rule["mode"]}
        />
      </div>
      <input type="hidden" name={"form[rules][#{@slot}][refs][]"} value="" />
      <ul :if={@rule["refs"] != []} class="m-0 flex list-none flex-col gap-1.5 p-0">
        <li
          :for={{ref, i} <- Enum.with_index(@rule["refs"])}
          class="flex items-start justify-between gap-2 rounded-field bg-base-100 py-1.5 pl-3 pr-1 text-[14px]"
        >
          <input type="hidden" name={"form[rules][#{@slot}][refs][]"} value={ref} />
          <span class="py-1">
            <span :if={i > 0} class="text-muted">
              {if @rule["mode"] == "or", do: "or ", else: "and "}
            </span>
            {@words[ref] || ref}
          </span>
          <button
            type="button"
            phx-click="remove_ref"
            phx-value-slot={@slot}
            phx-value-ref={ref}
            aria-label={"Remove: #{@words[ref] || ref}"}
            class="grid min-h-8 min-w-8 place-items-center rounded-field text-muted hover:text-error"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </li>
      </ul>
      <select name={"add[#{@slot}]"} class="select select-sm w-full">
        <option value="" selected>
          {if @rule["refs"] == [], do: "Add a condition…", else: "Add another condition…"}
        </option>
        <optgroup :for={{block, options} <- @groups} label={block}>
          <option :for={{ref, words} <- options} :if={ref not in @rule["refs"]} value={ref}>
            {words}
          </option>
        </optgroup>
      </select>
    </div>
    """
  end
end
