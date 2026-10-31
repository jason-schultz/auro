defmodule OpusWeb.ResearchLive do
  @moduledoc """
  Research page: the log of every strategy idea and test. Narrow it by
  verdict or search it, log a new idea or result, and move an entry along
  (idea → testing → worked, failed, or parked for another look).
  """
  use OpusWeb, :live_view

  import OpusWeb.Format, only: [date: 1]

  alias Opus.Research
  alias Opus.Research.Entry

  # The statuses, in page order (names: `status_name/1`).
  @statuses ~w(idea testing worked failed parked)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Research",
       status: "all",
       search: "",
       statuses: @statuses,
       areas: Entry.areas(),
       add_form: blank_form()
     )
     |> reload()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(status: status) |> reload()}
  end

  def handle_event("search", %{"search" => term}, socket) do
    {:noreply, socket |> assign(search: term) |> reload()}
  end

  def handle_event("add", %{"entry" => attrs}, socket) do
    case Research.create(attrs) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> put_flash(:info, "Logged “#{entry.title}”.")
         |> assign(add_form: blank_form())
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, add_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("set_status", %{"entry_id" => id, "status" => status}, socket) do
    case id |> Research.get!() |> Research.set_status(status) do
      {:ok, _entry} ->
        {:noreply, reload(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update that entry.")}
    end
  end

  defp blank_form, do: %Entry{} |> Research.change() |> to_form()

  defp reload(socket) do
    %{status: status, search: search} = socket.assigns

    assign(socket,
      entries: Research.list(status: status, search: search),
      counts: Research.counts()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
          <div class="flex items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t {copy("Research")} />
            </h1>
            <span class="text-[13px] text-muted">
              {@counts |> Map.values() |> Enum.sum()} <.t {copy("entries")} />
            </span>
          </div>
          <p class="text-[13px] text-muted">
            <.t {copy("What we tried, what held up, what didn't, and what's worth another look.")} />
          </p>
        </header>

        <div class="flex flex-wrap items-center gap-x-5 gap-y-3">
          <form id="search-form" phx-change="search" phx-submit="search">
            <input
              type="search"
              name="search"
              value={@search}
              placeholder="Search titles and numbers"
              aria-label="Search research"
              class="input w-56"
              phx-debounce="200"
            />
          </form>
          <div role="group" aria-label="Status" class="flex flex-wrap gap-1.5">
            <.chip status="all" current={@status}>
              <.t {pcopy("research", "All")} />
            </.chip>
            <.chip :for={status <- @statuses} status={status} current={@status}>
              <.t {status_name(status)} />
              <span class="text-muted">{@counts[status]}</span>
            </.chip>
          </div>
        </div>

        <details class="rounded-box border border-base-300 bg-base-200 px-5 py-4">
          <summary class="cursor-pointer text-[14px] font-medium text-primary">
            <.t {copy("Log an idea or a result")} />
          </summary>
          <.form for={@add_form} id="add-form" phx-submit="add" class="mt-4 flex flex-col gap-1">
            <div class="flex flex-wrap gap-3">
              <.input field={@add_form[:title]} label="Title" class="input w-80" />
              <.input
                field={@add_form[:area]}
                type="select"
                label="Area"
                options={@areas}
                class="select w-36"
              />
              <.input
                field={@add_form[:status]}
                type="select"
                label="Status"
                options={for status <- @statuses, do: {status_name(status).s, status}}
                class="select w-36"
              />
              <.input field={@add_form[:decided_on]} type="date" label="Decided" class="input w-40" />
            </div>
            <.input field={@add_form[:summary]} label="Verdict in a line" class="input w-full" />
            <.input
              field={@add_form[:evidence]}
              type="textarea"
              label="Key numbers"
              class="textarea w-full"
            />
            <.input
              field={@add_form[:details]}
              type="textarea"
              label="Details"
              class="textarea w-full"
            />
            <.input
              field={@add_form[:source]}
              label="Source (note or doc path)"
              class="input w-full"
            />
            <div><.button><.t {copy("Log it")} /></.button></div>
          </.form>
        </details>

        <p :if={@entries == []} class="text-[13px] text-muted">
          <.t {copy("Nothing matches.")} />
        </p>

        <ul :if={@entries != []} class="m-0 flex list-none flex-col p-0">
          <li
            :for={entry <- @entries}
            id={"entry-#{entry.id}"}
            class="flex flex-col gap-1.5 border-b border-neutral py-4 last:border-b-0"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
              <div class="flex min-w-0 flex-wrap items-baseline gap-x-3">
                <span class="text-[15px] font-medium">{entry.title}</span>
                <span class="text-[13px] text-muted">
                  {entry.area}<span :if={entry.decided_on}> · {date(entry.decided_on)}</span>
                </span>
              </div>
              <form id={"status-#{entry.id}"} phx-change="set_status" class="flex items-center gap-2">
                <.status_label status={entry.status} />
                <input type="hidden" name="entry_id" value={entry.id} />
                <select
                  name="status"
                  aria-label={"Status of #{entry.title}"}
                  class="select select-sm w-32"
                >
                  <option
                    :for={status <- @statuses}
                    value={status}
                    selected={status == entry.status}
                  >
                    {status_name(status).s}
                  </option>
                </select>
              </form>
            </div>
            <p class="text-[14px]">{entry.summary}</p>
            <p :if={entry.evidence} class="text-[13px] text-muted">{entry.evidence}</p>
            <details :if={entry.details} class="text-[13px]">
              <summary class="cursor-pointer text-muted hover:text-base-content">Details</summary>
              <p class="mt-1 whitespace-pre-line">{entry.details}</p>
            </details>
            <span :if={entry.source} class="text-[12px] text-muted">{entry.source}</span>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :status, :string, required: true
  attr :current, :string, required: true
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-status={@status}
      aria-pressed={to_string(@status == @current)}
      class={["text-[13px]", chip_class(@status == @current)]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp status_name("idea"), do: copy("Idea")
  defp status_name("testing"), do: copy("Testing")
  defp status_name("worked"), do: copy("Worked")
  defp status_name("failed"), do: copy("Failed")
  defp status_name("parked"), do: copy("Parked")
  defp status_name(other), do: %{s: other, wsb: other}

  attr :status, :string, required: true

  defp status_label(assigns) do
    ~H"""
    <span class={["text-[13px] font-medium", status_class(@status)]}>
      <.t {status_name(@status)} />
    </span>
    """
  end

  defp status_class("worked"), do: "text-success"
  defp status_class("failed"), do: "text-error"
  defp status_class("testing"), do: "text-info"
  defp status_class("parked"), do: "text-warning"
  defp status_class(_), do: "text-muted"
end
