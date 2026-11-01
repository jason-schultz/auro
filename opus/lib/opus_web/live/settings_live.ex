defmodule OpusWeb.SettingsLive do
  @moduledoc """
  Settings page: the keys, accounts and addresses Auro connects with
  (`Opus.Settings`), one card per integration. A secret is never shown
  again once saved, only how it ends; leaving its box empty keeps it. Each
  card's Test makes one read-only call to the provider
  (`Opus.Settings.Check`).

  Opus uses a change at once; the engine reads its settings when it starts,
  so the card says when a restart is needed.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Settings
  alias Opus.Settings.Check

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings", key_set: Settings.key_set?(), checking: nil, notes: %{})
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      cards: Enum.map(Settings.providers(), &Map.put(&1, :view, Settings.view(&1)))
    )
  end

  @impl true
  def handle_event("save", %{"provider" => id} = params, socket) do
    provider = Settings.provider(id)
    entered = Map.get(params, "fields", %{})

    results =
      for field <- provider.fields,
          value = Map.get(entered, field.name),
          is_binary(value),
          # An empty secret box keeps what's saved.
          not (field.secret and String.trim(value) == ""),
          do: Settings.put(field.name, value)

    note =
      cond do
        {:error, :no_key} in results ->
          "Secrets can't be saved: AURO_SECRETS_KEY isn't set in Opus's settings."

        :engine in provider.used_by ->
          "Saved. The engine reads these when it starts: restart it to use them " <>
            "(scripts/deploy.sh, or launchctl kickstart -k gui/$UID/ca.carbonandfire.auro.engine)."

        true ->
          "Saved. In use now."
      end

    {:noreply, socket |> put_note(id, note) |> load()}
  end

  def handle_event("clear", %{"name" => name, "provider" => id}, socket) do
    :ok = Settings.put(name, "")
    {:noreply, socket |> put_note(id, "Removed #{name}: the .env value applies again.") |> load()}
  end

  def handle_event("check", %{"provider" => id}, socket) do
    provider = Settings.provider(id)

    {:noreply,
     socket
     |> assign(checking: id)
     |> start_async({:check, id}, fn -> {provider, Check.run(provider)} end)}
  end

  @impl true
  def handle_async({:check, id}, {:ok, {provider, result}}, socket) do
    words = elem(result, 1)
    :ok = Settings.record_check(provider, words)
    {:noreply, socket |> assign(checking: nil) |> put_note(id, words) |> load()}
  end

  def handle_async({:check, id}, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(checking: nil) |> put_note(id, "The test didn't finish.")}

  defp put_note(socket, id, words),
    do: assign(socket, notes: Map.put(socket.assigns.notes, id, words))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <header class="flex flex-col gap-1">
          <h1 class="text-[22px] font-semibold tracking-tight"><.t {copy("Settings")} /></h1>
          <p class="m-0 text-[13px] text-muted">
            The keys and accounts Auro connects with. Saved here, they take the place of the
            same names in .env; secrets are kept encrypted and never shown again.
          </p>
          <p :if={!@key_set} class="m-0 text-[13px] text-warning">
            AURO_SECRETS_KEY isn't set, so secrets can't be saved yet. Add it (openssl rand -hex 32)
            to Opus's and the engine's settings, the same in both, and restart them.
          </p>
        </header>

        <div class="grid gap-4 xl:grid-cols-2">
          <.card :for={card <- @cards} card={card} note={@notes[card.id]} checking={@checking} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :card, :map, required: true
  attr :note, :string, default: nil
  attr :checking, :string, default: nil

  defp card(assigns) do
    ~H"""
    <section
      id={"settings-#{@card.id}"}
      aria-labelledby={"settings-#{@card.id}-name"}
      class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
    >
      <div class="flex flex-col gap-0.5">
        <h2 id={"settings-#{@card.id}-name"} class="m-0 text-[15px] font-semibold">
          {@card.name}
        </h2>
        <p class="m-0 text-[13px] text-muted">{@card.about} {used_by(@card.used_by)}</p>
      </div>

      <form id={"settings-#{@card.id}-form"} phx-submit="save" class="flex flex-col gap-3">
        <input type="hidden" name="provider" value={@card.id} />
        <label :for={field <- @card.view.fields} class="flex flex-col gap-1 text-[13px]">
          <span class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="font-medium">{field.label}</span>
            <span class="text-[12px] text-muted">
              {status(field)}
              <button
                :if={field.stored}
                type="button"
                phx-click="clear"
                phx-value-name={field.name}
                phx-value-provider={@card.id}
                class="ml-2 underline hover:text-base-content"
              >
                Remove
              </button>
            </span>
          </span>
          <input
            type={if field.secret, do: "password", else: "text"}
            name={"fields[#{field.name}]"}
            value={if field.secret, do: "", else: field[:value]}
            placeholder={placeholder(field)}
            autocomplete="off"
            class="input input-sm w-full"
          />
          <span :if={field[:hint]} class="text-[12px] text-muted">{field.hint}</span>
        </label>
        <div class="flex flex-wrap items-center gap-3">
          <button type="submit" class="btn btn-sm btn-primary">Save</button>
          <button
            type="button"
            phx-click="check"
            phx-value-provider={@card.id}
            disabled={@checking == @card.id}
            class="btn btn-sm"
          >
            {if @checking == @card.id, do: "Testing…", else: "Test"}
          </button>
          <span :if={@card.view.tested_at && !@note} class="text-[12px] text-muted">
            Last test {date(@card.view.tested_at)}: {@card.view.test_result}
          </span>
        </div>
        <p :if={@note} role="status" class="m-0 text-[13px]">{@note}</p>
      </form>
    </section>
    """
  end

  defp used_by([:engine, :opus]), do: "Used by the engine and Opus."
  defp used_by([:engine]), do: "Used by the engine."
  defp used_by([:opus]), do: "Used by Opus."

  defp status(%{stored: false}), do: "not saved here (.env applies)"
  defp status(%{unreadable: true}), do: "saved, but it won't open with this AURO_SECRETS_KEY"
  defp status(%{secret: true, ends: ends, saved_at: at}), do: "saved #{date(at)}, ends …#{ends}"
  defp status(%{saved_at: at}), do: "saved #{date(at)}"

  defp placeholder(%{secret: true, stored: true}), do: "Leave empty to keep it"
  defp placeholder(%{secret: true}), do: "Paste it here"
  defp placeholder(_field), do: ""
end
