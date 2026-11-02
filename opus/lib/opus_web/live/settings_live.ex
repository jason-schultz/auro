defmodule OpusWeb.SettingsLive do
  @moduledoc """
  Settings: Integrations and Appearance.

  Integrations is one page of tiles under group headings (`Opus.Settings`),
  with a "Needs attention" strip on top when a connection has a problem.
  A tile opens its panel at its own address
  (`/settings/integrations/:id`), so the back button closes it and other
  pages can link straight to one.

  What each tile says comes from real checks (`Opus.Settings.Status`).
  Saving asks the engine to check the new values and put them in use, so
  nothing waits for a restart except switching the OANDA account itself. A
  save anywhere is broadcast, so every open Settings page updates.

  Appearance holds the theme, which used to be a switch in the top bar;
  it's kept per browser, as before.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  require Logger

  alias Opus.Auro.Client
  alias Opus.Settings
  alias Opus.Settings.{Check, Status}

  @topic "settings"

  @tones %{
    "blue" => "#5aa9f2",
    "green" => "#4fd1a0",
    "teal" => "#56c7d6",
    "indigo" => "#8b93f6"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Opus.PubSub, @topic)

    socket =
      socket
      |> assign(
        page_title: "Settings",
        key_set: Settings.key_set?(),
        # The engine's answers: nil until they arrive.
        engine: nil,
        questrade: nil,
        # The integration whose save or Test is waiting on a check.
        checking: nil,
        notes: %{},
        # Bumped after each token send so the box is replaced, empty.
        token_field: 0,
        open: nil
      )
      |> load_views()

    {:ok, if(connected?(socket), do: ask_engine(socket), else: socket)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Settings.integration(id) do
      %{kind: kind} = integration when kind != :later ->
        {:noreply, assign(socket, open: integration)}

      _ ->
        {:noreply, push_patch(socket, to: ~p"/settings/integrations")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, open: nil)}

  defp load_views(socket) do
    views =
      for {_group, integrations} <- Settings.groups(),
          %{kind: :keyed} = integration <- integrations,
          into: %{},
          do: {integration.id, Settings.view(integration)}

    assign(socket, views: views)
  end

  defp ask_engine(socket) do
    socket
    |> start_async(:engine, &Client.settings_status/0)
    |> start_async(:questrade, &questrade_status/0)
  end

  # Whether the engine is connected to Questrade, by its own token: the same
  # read the Accounts page makes.
  defp questrade_status do
    with {:ok, brokers} <- Client.list_brokers(),
         %{} = status <- Enum.find(brokers, &(&1["broker"] == "questrade")) do
      {:ok, status}
    else
      nil -> {:error, "The engine didn't list Questrade."}
      {:error, reason} -> {:error, Client.describe_error(reason)}
    end
  end

  @impl true
  def handle_event("close", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/settings/integrations")}

  def handle_event("save", %{"integration" => id} = params, socket) do
    integration = Settings.integration(id)
    entered = Map.get(params, "fields", %{})

    results =
      for field <- integration.fields,
          value = Map.get(entered, field.name),
          is_binary(value),
          # An empty secret box keeps what's saved.
          not (field.secret and String.trim(value) == ""),
          do: Settings.put(field.name, value)

    if {:error, :no_key} in results do
      {:noreply,
       put_note(
         socket,
         id,
         "Secrets can't be saved: AURO_SECRETS_KEY isn't set in Opus's settings."
       )}
    else
      {:noreply, socket |> load_views() |> check(integration)}
    end
  end

  def handle_event("remove", %{"name" => name, "integration" => id}, socket) do
    :ok = Settings.put(name, "")
    {:noreply, socket |> load_views() |> check(Settings.integration(id))}
  end

  def handle_event("test", %{"integration" => "questrade"}, socket),
    do:
      {:noreply, socket |> assign(questrade: nil) |> start_async(:questrade, &questrade_status/0)}

  def handle_event("test", %{"integration" => id}, socket),
    do: {:noreply, check(socket, Settings.integration(id))}

  # The token is a secret: it goes straight to the engine and is never
  # assigned, logged or shown. Phoenix filters any parameter named like
  # "token" out of its own event logs.
  def handle_event("connect_questrade", %{"questrade_token" => token}, socket) do
    socket = update(socket, :token_field, &(&1 + 1))

    case String.trim(token) do
      "" ->
        {:noreply, put_note(socket, "questrade", "Paste the token from Questrade first.")}

      token ->
        {:noreply,
         socket
         |> assign(checking: "questrade")
         |> put_note("questrade", nil)
         |> start_async(:questrade_connect, fn -> Client.connect_questrade(token) end)}
    end
  end

  # A connection the engine uses is checked by the engine, which puts it in
  # use if it works; one only Opus uses (Discord) is checked here.
  defp check(socket, %{engine: connection, id: id}) do
    socket
    |> assign(checking: id)
    |> put_note(id, nil)
    |> start_async({:apply, id}, fn -> Client.apply_settings(connection) end)
  end

  defp check(socket, %{id: id} = integration) do
    socket
    |> assign(checking: id)
    |> put_note(id, nil)
    |> start_async({:check, id}, fn -> Check.run(integration) end)
  end

  @impl true
  def handle_async(:engine, {:ok, {:ok, statuses}}, socket),
    do: {:noreply, assign(socket, engine: {:ok, statuses})}

  def handle_async(:engine, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, engine: {:error, Client.describe_error(reason)})}

  def handle_async(:engine, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, engine: {:error, "Asking the engine didn't finish."})}

  def handle_async(:questrade, {:ok, result}, socket),
    do: {:noreply, assign(socket, questrade: result)}

  def handle_async(:questrade, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, questrade: {:error, "Asking the engine didn't finish."})}

  def handle_async({:apply, id}, {:ok, {:ok, %{"status" => status}}}, socket) do
    connection = Settings.integration(id).engine
    statuses = Map.put(engine_statuses(socket), connection, status)
    changed()

    {:noreply,
     socket
     |> assign(checking: nil, engine: {:ok, statuses})
     |> put_note(id, status["words"])}
  end

  def handle_async({:apply, id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(checking: nil)
     |> put_note(
       id,
       "Saved, but the engine didn't answer (#{Client.describe_error(reason)}). " <>
         "It reads the saved values when it starts."
     )}
  end

  def handle_async({:check, id}, {:ok, {result, words}}, socket) do
    :ok = Settings.record_check(Settings.integration(id), result == :ok, words)
    changed()
    {:noreply, socket |> assign(checking: nil) |> load_views() |> put_note(id, words)}
  end

  def handle_async(:questrade_connect, {:ok, {:ok, %{"connected" => true}}}, socket) do
    changed()

    {:noreply,
     socket
     |> assign(checking: nil)
     |> put_note("questrade", "Questrade is connected again.")
     |> start_async(:questrade, &questrade_status/0)}
  end

  def handle_async(:questrade_connect, {:ok, {:ok, answer}}, socket) do
    why = if is_binary(answer["error"]), do: " Questrade said: #{answer["error"]}", else: ""

    {:noreply,
     socket
     |> assign(checking: nil)
     |> put_note(
       "questrade",
       "Questrade took the token but then didn't answer for the accounts.#{why}"
     )}
  end

  def handle_async(:questrade_connect, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(checking: nil)
     |> put_note(
       "questrade",
       "That didn't connect, and nothing changed. #{Client.describe_error(reason)} " <>
         "A token works only once, so generate a fresh one before trying again."
     )}
  end

  def handle_async(:questrade_connect, {:exit, _reason}, socket) do
    # Not the reason: a crash report could carry the call's arguments.
    Logger.error("[Settings] Connecting Questrade crashed")

    {:noreply,
     socket
     |> assign(checking: nil)
     |> put_note("questrade", "Connecting Questrade failed. Check the Opus log.")}
  end

  def handle_async({_kind, id}, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(checking: nil) |> put_note(id, "The check didn't finish.")}

  @impl true
  def handle_info(:settings_changed, socket),
    do: {:noreply, socket |> load_views() |> ask_engine()}

  defp changed, do: Phoenix.PubSub.broadcast_from(Opus.PubSub, self(), @topic, :settings_changed)

  defp engine_statuses(%{assigns: %{engine: {:ok, statuses}}}), do: statuses
  defp engine_statuses(_socket), do: %{}

  defp put_note(socket, id, words),
    do: assign(socket, notes: Map.put(socket.assigns.notes, id, words))

  defp known(assigns), do: Map.take(assigns, [:engine, :questrade, :views])

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <h1 class="text-[22px] font-semibold tracking-tight"><.t {copy("Settings")} /></h1>
        <div class="flex flex-wrap items-start gap-x-10 gap-y-6">
          <nav
            aria-label="Settings sections"
            class="grid w-full grid-cols-2 gap-1 rounded-field border border-base-300 bg-base-200 p-1 sm:flex sm:w-48 sm:flex-col sm:border-0 sm:bg-transparent sm:p-0"
          >
            <.section_link to={~p"/settings/integrations"} current={@live_action == :integrations}>
              Integrations
            </.section_link>
            <.section_link to={~p"/settings/appearance"} current={@live_action == :appearance}>
              Appearance
            </.section_link>
          </nav>
          <div class="flex min-w-0 flex-[999_1_560px] flex-col gap-8">
            <.integrations
              :if={@live_action == :integrations}
              known={known(assigns)}
              key_set={@key_set}
            />
            <.appearance :if={@live_action == :appearance} />
          </div>
        </div>
      </div>
      <.panel
        :if={@open}
        integration={@open}
        known={known(assigns)}
        view={@views[@open.id]}
        note={@notes[@open.id]}
        busy={@checking == @open.id}
        token_field={@token_field}
      />
    </Layouts.app>
    """
  end

  attr :to, :string, required: true
  attr :current, :boolean, required: true
  slot :inner_block, required: true

  defp section_link(assigns) do
    ~H"""
    <.link
      patch={@to}
      aria-current={@current && "page"}
      class={[
        "flex min-h-10 items-center justify-center rounded-field px-3 text-sm sm:justify-start",
        if(@current,
          do: "bg-base-300 font-semibold sm:bg-base-200",
          else: "text-muted hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :known, :map, required: true
  attr :key_set, :boolean, required: true

  defp integrations(assigns) do
    assigns = assign(assigns, attention: Status.needing_attention(assigns.known))

    ~H"""
    <div class="flex flex-col gap-1.5">
      <h2 class="text-[17px] font-semibold">Integrations</h2>
      <p class="m-0 text-sm text-muted">
        The services the lab connects to. A saved key is checked, then put in use straight away, with no restart.
      </p>
      <p :if={!@key_set} class="m-0 text-sm text-warning">
        AURO_SECRETS_KEY isn't set, so secrets can't be saved yet. Add it (openssl rand -hex 32)
        to Opus's and the engine's settings, the same in both, and restart them.
      </p>
    </div>

    <section
      :if={@attention != []}
      id="needs-attention"
      aria-labelledby="attention-h"
      class="flex flex-col gap-2.5 rounded-box border border-error/45 bg-base-200 px-5 py-4"
    >
      <h3 id="attention-h" class="m-0 text-[13px] font-semibold text-error">Needs attention</h3>
      <div
        :for={{integration, line} <- @attention}
        class="flex flex-wrap items-center justify-between gap-3"
      >
        <p class="m-0 flex items-center gap-2.5 text-sm">
          <.dot state={:problem} />
          <span><strong class="font-semibold">{integration.name}:</strong> {line}</span>
        </p>
        <.link patch={~p"/settings/integrations/#{integration.id}"} class="btn btn-sm min-h-10">
          Open {integration.name}
        </.link>
      </div>
    </section>

    <section :for={{group, members} <- Settings.groups()} class="flex flex-col gap-3">
      <h3 class="m-0 text-[13px] font-semibold uppercase tracking-wider text-muted">{group}</h3>
      <div class="grid grid-cols-3 gap-2 sm:grid-cols-[repeat(auto-fill,minmax(150px,1fr))] sm:gap-3">
        <.tile :for={integration <- members} integration={integration} known={@known} />
      </div>
    </section>
    """
  end

  attr :integration, :map, required: true
  attr :known, :map, required: true

  defp tile(%{integration: %{kind: :later}} = assigns) do
    ~H"""
    <div class="flex min-h-[124px] flex-col items-center gap-2 rounded-box border border-dashed border-base-300 px-2 pb-3 pt-4 text-center">
      <span
        aria-hidden="true"
        class="flex size-11 items-center justify-center rounded-full bg-neutral text-[13px] font-bold text-neutral-content"
      >
        {@integration.initials}
      </span>
      <span class="text-sm font-semibold leading-tight text-base-content/80">
        {@integration.name}
      </span>
      <span class="text-xs text-muted">Coming later</span>
    </div>
    """
  end

  defp tile(assigns) do
    {state, word, _line} = Status.of(assigns.integration, assigns.known)
    assigns = assign(assigns, state: state, word: word)

    ~H"""
    <.link
      patch={~p"/settings/integrations/#{@integration.id}"}
      id={"tile-#{@integration.id}"}
      class={[
        "flex min-h-[124px] flex-col items-center gap-2 rounded-box border bg-base-200 px-2 pb-3 pt-4 text-center hover:border-primary",
        if(@state in [:problem, :restart], do: "border-error/50", else: "border-base-300")
      ]}
    >
      <.logo integration={@integration} />
      <span class="text-sm font-semibold leading-tight">{@integration.name}</span>
      <span class="flex items-center gap-1.5 text-xs text-muted">
        <.dot state={@state} />{@word}
      </span>
    </.link>
    """
  end

  attr :integration, :map, required: true

  defp logo(assigns) do
    assigns = assign(assigns, color: Map.get(@tones, assigns.integration[:tone], "#adb5c0"))

    ~H"""
    <span
      aria-hidden="true"
      class="flex size-11 flex-none items-center justify-center rounded-full text-[14px] font-bold text-[#111419]"
      style={"background: #{@color}"}
    >
      {@integration.initials}
    </span>
    """
  end

  attr :state, :atom, required: true

  defp dot(%{state: :checking} = assigns) do
    ~H"""
    <span aria-hidden="true" class="loading loading-spinner size-3"></span>
    """
  end

  defp dot(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-block size-2.5 flex-none rounded-full",
        case @state do
          :working -> "bg-success"
          :problem -> "bg-error"
          :restart -> "bg-warning"
          :none -> "border-2 border-base-content/50"
          _ -> "bg-base-content/40"
        end
      ]}
    ></span>
    """
  end

  attr :integration, :map, required: true
  attr :known, :map, required: true
  attr :view, :map, default: nil
  attr :note, :string, default: nil
  attr :busy, :boolean, required: true
  attr :token_field, :integer, required: true

  defp panel(assigns) do
    {state, _word, line} = Status.of(assigns.integration, assigns.known)
    assigns = assign(assigns, state: state, line: line)

    ~H"""
    <div class="fixed inset-0 z-40 bg-black/60" phx-click="close" aria-hidden="true"></div>
    <aside
      id={"panel-#{@integration.id}"}
      role="dialog"
      aria-modal="true"
      aria-labelledby="panel-name"
      phx-window-keydown="close"
      phx-key="Escape"
      class="fixed inset-y-0 right-0 z-50 flex w-full max-w-[460px] flex-col gap-5 overflow-y-auto border-l border-base-300 bg-base-200 px-7 pb-10 pt-6"
    >
      <div class="flex items-start gap-3.5">
        <.logo integration={@integration} />
        <div class="flex flex-1 flex-col gap-1">
          <h2 id="panel-name" class="m-0 text-lg font-semibold">{@integration.name}</h2>
          <span class="flex items-center gap-2 text-[13px]">
            <.dot state={@state} />{headline(@state, @line)}
          </span>
        </div>
        <.link patch={~p"/settings/integrations"} aria-label="Close" class="btn btn-sm size-10 p-0">
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>

      <p class="m-0 text-sm leading-relaxed">
        {@integration.about}
        <span :if={@integration[:used_by]} class="text-muted">{used_by(@integration.used_by)}</span>
      </p>

      <p
        :if={@state in [:problem, :restart] and is_binary(@line)}
        role="status"
        class={[
          "m-0 rounded-field border px-3.5 py-3 text-sm leading-relaxed",
          if(@state == :problem, do: "border-error/45", else: "border-warning/50")
        ]}
      >
        {@line}
      </p>

      <p
        :if={@integration.id == "oanda-practice"}
        class="m-0 rounded-field bg-base-100 px-3.5 py-3 text-[13px] leading-relaxed"
      >
        Prices from: OANDA Practice. Once OANDA Real is set up and working, prices come from there instead.
      </p>

      <.keyed_form
        :if={@integration.kind == :keyed}
        integration={@integration}
        view={@view}
        busy={@busy}
      />
      <.questrade_form :if={@integration.kind == :questrade} busy={@busy} field={@token_field} />

      <p :if={@note} role="status" class="m-0 border-t border-base-300 pt-3.5 text-[13px]">
        {@note}
      </p>
      <p
        :if={!@note && @view && @view.check}
        class="m-0 border-t border-base-300 pt-3.5 text-[13px] text-muted"
      >
        Last test {clock(@view.check.at)}, {date(@view.check.at)}: {@view.check.words}
      </p>
    </aside>
    """
  end

  defp headline(:problem, _line), do: "Problem"
  defp headline(:restart, _line), do: "Restart to switch account"
  defp headline(_state, line), do: line

  attr :integration, :map, required: true
  attr :view, :map, required: true
  attr :busy, :boolean, required: true

  defp keyed_form(assigns) do
    ~H"""
    <form id={"settings-#{@integration.id}-form"} phx-submit="save" class="flex flex-col gap-[18px]">
      <input type="hidden" name="integration" value={@integration.id} />
      <div :for={field <- @view.fields} class="flex flex-col gap-1.5">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <label for={"field-#{field.name}"} class="text-sm font-semibold">{field.label}</label>
          <span class="text-xs text-muted">
            {saved_line(field)}
            <button
              :if={field.stored}
              type="button"
              phx-click="remove"
              phx-value-name={field.name}
              phx-value-integration={@integration.id}
              class="ml-2 underline hover:text-base-content"
            >
              Remove
            </button>
          </span>
        </div>
        <input
          id={"field-#{field.name}"}
          type={if field.secret, do: "password", else: "text"}
          name={"fields[#{field.name}]"}
          value={if field.secret, do: "", else: field[:value]}
          placeholder={placeholder(field)}
          autocomplete="off"
          class="input w-full"
        />
        <span :if={field[:hint]} class="text-xs leading-snug text-muted">{field.hint}</span>
      </div>
      <div class="flex flex-wrap gap-2.5">
        <button type="submit" class="btn btn-primary" disabled={@busy}>
          {if @busy, do: "Checking…", else: "Save and check"}
        </button>
        <button
          type="button"
          class="btn"
          phx-click="test"
          phx-value-integration={@integration.id}
          disabled={@busy}
        >
          Test
        </button>
      </div>
    </form>
    """
  end

  attr :busy, :boolean, required: true
  attr :field, :integer, required: true

  defp questrade_form(assigns) do
    ~H"""
    <form id="questrade-connect" phx-submit="connect_questrade" class="flex flex-col gap-3.5">
      <div class="flex flex-col gap-1.5">
        <label for={"questrade-token-#{@field}"} class="text-sm font-semibold">New token</label>
        <input
          id={"questrade-token-#{@field}"}
          type="password"
          name="questrade_token"
          autocomplete="off"
          spellcheck="false"
          placeholder="Paste it here"
          class="input w-full"
        />
        <span class="text-xs leading-snug text-muted">
          Only needed when Questrade stops accepting the engine's token. It works once, connects
          the engine straight away, and isn't kept by Opus.
        </span>
      </div>
      <ol class="m-0 list-decimal pl-5 text-[13px] leading-relaxed">
        <li>Log in to Questrade.</li>
        <li>Under your name, open API centre.</li>
        <li>Find this app and choose Generate new token.</li>
        <li>Copy it and paste it above.</li>
      </ol>
      <div class="flex flex-wrap gap-2.5">
        <button type="submit" class="btn btn-primary" disabled={@busy}>
          {if @busy, do: "Connecting…", else: "Connect"}
        </button>
        <button type="button" class="btn" phx-click="test" phx-value-integration="questrade">
          Test
        </button>
      </div>
    </form>
    """
  end

  defp used_by([:engine, :opus]), do: "Used by the engine and Opus."
  defp used_by([:engine]), do: "Used by the engine."
  defp used_by([:opus]), do: "Used by Opus."

  defp saved_line(%{stored: false}), do: "not saved here (.env applies)"
  defp saved_line(%{unreadable: true}), do: "saved, but it won't open with this AURO_SECRETS_KEY"

  defp saved_line(%{secret: true, ends: ends, saved_at: at}),
    do: "saved #{date(at)} · ends …#{ends}"

  defp saved_line(%{saved_at: at}), do: "saved #{date(at)}"

  defp placeholder(%{secret: true, stored: true}), do: "Leave empty to keep it"
  defp placeholder(%{secret: true}), do: "Paste it here"
  defp placeholder(_field), do: ""

  # ── Appearance ──────────────────────────────────────────────────────────

  @themes [
    {"system", "System", "Follows your computer: light by day, dark at night."},
    {"light", "Light", "White cards, dark green for gains."},
    {"dark", "Dark", "Calm and dim, mint green for gains."},
    {"wsb", "WSB", "Loud, with the WallStreetBets wording."}
  ]

  defp appearance(assigns) do
    assigns = assign(assigns, themes: @themes)

    ~H"""
    <div class="flex flex-col gap-1.5">
      <h2 class="text-[17px] font-semibold">Appearance</h2>
      <p class="m-0 text-sm text-muted">
        How the lab looks in this browser. Each browser keeps its own choice.
      </p>
    </div>
    <section aria-labelledby="theme-h" class="flex flex-col gap-3">
      <h3 id="theme-h" class="m-0 text-sm font-semibold">Theme</h3>
      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <button
          :for={{id, name, about} <- @themes}
          type="button"
          id={"theme-#{id}"}
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme={id}
          class={[
            "flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 p-3 text-left hover:border-primary",
            selected_class(id)
          ]}
        >
          <.theme_preview id={id} />
          <span class="flex flex-col gap-0.5">
            <span class="text-sm font-semibold">{name}</span>
            <span class="text-xs text-muted">{about}</span>
          </span>
        </button>
      </div>
    </section>
    """
  end

  # The chosen theme's card is outlined, from the attributes the theme
  # script sets on <html>. Spelled out whole so Tailwind finds each class.
  defp selected_class("system"),
    do:
      "[[data-theme-source=system]_&]:border-primary [[data-theme-source=system]_&]:ring-1 [[data-theme-source=system]_&]:ring-primary"

  defp selected_class("light"),
    do:
      "[[data-theme-source=user][data-theme=light]_&]:border-primary [[data-theme-source=user][data-theme=light]_&]:ring-1 [[data-theme-source=user][data-theme=light]_&]:ring-primary"

  defp selected_class("dark"),
    do:
      "[[data-theme-source=user][data-theme=dark]_&]:border-primary [[data-theme-source=user][data-theme=dark]_&]:ring-1 [[data-theme-source=user][data-theme=dark]_&]:ring-primary"

  defp selected_class("wsb"),
    do:
      "[[data-theme-source=user][data-theme=wsb]_&]:border-primary [[data-theme-source=user][data-theme=wsb]_&]:ring-1 [[data-theme-source=user][data-theme=wsb]_&]:ring-primary"

  @previews %{
    "light" => %{bg: "#f1f2f5", bar: "#ffffff", line: "#d3d8df", text: "#101317", up: "#0b6d4f"},
    "dark" => %{bg: "#111419", bar: "#181c22", line: "#2f353f", text: "#f1f3f6", up: "#4fd1a0"},
    "wsb" => %{bg: "#0b0b10", bar: "#14141b", line: "#26262f", text: "#4ade80", up: "#ffd54f"}
  }

  attr :id, :string, required: true

  # A small picture of a page in the theme's own colours (from app.css).
  defp theme_preview(%{id: "system"} = assigns) do
    assigns = assign(assigns, light: @previews["light"], dark: @previews["dark"])

    ~H"""
    <span aria-hidden="true" class="flex h-28 overflow-hidden rounded-field">
      <.preview_half {@light} />
      <.preview_half {@dark} />
    </span>
    """
  end

  defp theme_preview(%{id: id} = assigns) do
    assigns = assign(assigns, colours: @previews[id])

    ~H"""
    <span aria-hidden="true" class="flex h-28 overflow-hidden rounded-field">
      <.preview_half {@colours} />
    </span>
    """
  end

  attr :bg, :string, required: true
  attr :bar, :string, required: true
  attr :line, :string, required: true
  attr :text, :string, required: true
  attr :up, :string, required: true

  defp preview_half(assigns) do
    ~H"""
    <span class="flex flex-1 flex-col" style={"background: #{@bg}"}>
      <span class="block h-4" style={"background: #{@bar}; border-bottom: 1px solid #{@line}"}></span>
      <span class="flex flex-1 flex-col gap-2 p-3">
        <span class="text-base font-bold" style={"color: #{@text}"}>$12,480</span>
        <span class="block h-1.5 w-3/4 rounded" style={"background: #{@up}"}></span>
        <span class="block h-1.5 w-1/2 rounded" style={"background: #{@line}"}></span>
      </span>
    </span>
    """
  end
end
