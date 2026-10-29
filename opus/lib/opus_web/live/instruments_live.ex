defmodule OpusWeb.InstrumentsLive do
  @moduledoc """
  Instruments page: the security master. Search it, narrow it to one market
  or to the live listings, add a listing by its vendor spelling, and tick
  which feeds store data for it. The feed workers read these flags on their
  next run.
  """
  use OpusWeb, :live_view

  require Logger

  alias Opus.Auro.Client
  alias Opus.Instruments
  alias Opus.Instruments.Instrument

  @add_defaults %{"spelling" => "", "asset_class" => "equity"}

  @groups [{"all", "All"}, {"oanda", "OANDA"}, {"canada", "Canada"}, {"us", "US"}]

  @feeds [
    {:feed_questrade_bars, "Questrade bars"},
    {:feed_massive_daily, "Massive daily"},
    {:feed_options_chain, "Option chains"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Instruments",
       search: "",
       group: "all",
       show_inactive: false,
       groups: @groups,
       add_form: to_form(@add_defaults, as: :listing),
       feeds: @feeds,
       asset_classes: Instrument.asset_classes(),
       busy: false
     )
     |> reload()}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    {:noreply, socket |> assign(search: term) |> reload()}
  end

  def handle_event("group", %{"group" => group}, socket) do
    {:noreply, socket |> assign(group: group) |> reload()}
  end

  def handle_event("inactive", _params, socket) do
    {:noreply, socket |> assign(show_inactive: !socket.assigns.show_inactive) |> reload()}
  end

  def handle_event("toggle", %{"id" => id, "flag" => flag}, socket) do
    with {:ok, flag} <- Instrument.flag(flag),
         {:ok, _} <- id |> Instruments.get!() |> Instruments.toggle(flag) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update that instrument.")}
    end
  end

  def handle_event(
        "add",
        %{"listing" => %{"spelling" => spelling, "asset_class" => class}},
        socket
      ) do
    case Instruments.add(spelling, class) do
      {:ok, instrument} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added #{instrument.exchange}:#{instrument.symbol}.")
         |> assign(add_form: to_form(@add_defaults, as: :listing))
         |> reload()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, describe(changeset))}
    end
  end

  # Asking Questrade takes up to a few minutes, so it runs in the
  # background: the page stays usable and the button says it's busy.
  def handle_event("enrich", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("enrich", _params, socket) do
    {:noreply, socket |> assign(busy: true) |> start_async(:enrich, &Instruments.enrich/0)}
  end

  @impl true
  def handle_async(:enrich, {:ok, {:ok, %{"resolved" => resolved, "failed" => failed}}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Questrade identified #{resolved} listings; #{length(failed)} failed.")
     |> assign(busy: false)
     |> reload()}
  end

  def handle_async(:enrich, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> put_flash(:error, Client.describe_error(reason)) |> assign(busy: false)}
  end

  def handle_async(:enrich, {:ok, other}, socket) do
    Logger.error("[Instruments] Unexpected enrich answer: #{inspect(other)}")

    {:noreply,
     socket
     |> put_flash(:error, "Auro gave an answer the page can't read.")
     |> assign(busy: false)}
  end

  def handle_async(:enrich, {:exit, reason}, socket) do
    Logger.error("[Instruments] Enrich crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(:error, "Asking Questrade failed. Check the Opus log.")
     |> assign(busy: false)}
  end

  defp reload(socket) do
    %{search: search, group: group, show_inactive: show_inactive} = socket.assigns

    assign(socket,
      instruments: Instruments.list(search: search, group: group, active_only: !show_inactive)
    )
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
          <div class="flex items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t {copy("Instruments")} />
            </h1>
            <span class="text-[13px] text-muted">{length(@instruments)}
            <.t {copy("listings shown")} /></span>
          </div>
          <p class="text-[13px] text-muted">
            <.t {copy("Every listing Auro knows and which feeds store data for it. Changes apply on the next run.")} />
          </p>
        </header>

        <div class="flex flex-wrap items-center gap-x-5 gap-y-3">
          <form id="search-form" phx-change="search" phx-submit="search">
            <input
              type="search"
              name="search"
              value={@search}
              placeholder="Search any spelling"
              aria-label="Search instruments"
              class="input w-56"
              phx-debounce="200"
            />
          </form>
          <div role="group" aria-label="Market" class="flex flex-wrap gap-1.5">
            <button
              :for={{group, label} <- @groups}
              type="button"
              phx-click="group"
              phx-value-group={group}
              aria-pressed={to_string(group == @group)}
              class={[
                "rounded-field border px-3 py-1.5 text-[13px] font-medium",
                if(group == @group,
                  do: "border-primary text-primary",
                  else: "border-base-300 text-muted hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <label class="flex cursor-pointer items-center gap-2 text-[13px] text-muted">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={@show_inactive}
              phx-click="inactive"
            /> <.t {copy("Show retired")} />
          </label>
        </div>

        <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
          <.form for={@add_form} id="add-form" phx-submit="add" class="flex flex-wrap items-end gap-3">
            <.input
              field={@add_form[:spelling]}
              label="Add a listing"
              placeholder="RY.TO, SPY, EUR_USD"
              class="input w-48"
            />
            <.input
              field={@add_form[:asset_class]}
              type="select"
              label="Class"
              options={@asset_classes}
              class="select w-36"
            />
            <.button class="mb-2">Add</.button>
          </.form>
          <div class="mb-2 flex flex-col items-end gap-1">
            <button
              type="button"
              phx-click="enrich"
              disabled={@busy}
              class="text-[14px] font-medium text-primary hover:brightness-110 disabled:opacity-60"
            >
              <span :if={@busy}>Asking Questrade…</span>
              <.t :if={!@busy} {copy("Identify via Questrade")} />
            </button>
            <span class="text-[12px] text-muted">fills the symbol id, exchange and currency for new listings</span>
          </div>
        </div>

        <p :if={@instruments == []} class="text-[13px] text-muted">
          <.t {copy("Nothing matches.")} />
        </p>

        <div
          :if={@instruments != []}
          class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5"
        >
          <table class="w-full min-w-[760px] border-collapse text-sm">
            <thead>
              <tr class="text-left text-xs text-muted">
                <th class="border-b border-base-300 py-2.5 font-medium">
                  <.t {copy("Listing")} />
                </th>
                <th class="border-b border-base-300 py-2.5 font-medium">
                  <.t {copy("Vendor names")} />
                </th>
                <th class="border-b border-base-300 py-2.5 text-center font-medium">
                  <.t {copy("Active")} />
                </th>
                <th
                  :for={{_flag, label} <- @feeds}
                  class="border-b border-base-300 py-2.5 text-center font-medium"
                >
                  {label}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={i <- @instruments}
                id={"instrument-#{i.id}"}
                class={["border-b border-neutral last:border-b-0", !i.active && "opacity-60"]}
              >
                <td class="py-2.5 pr-4">
                  <span class="font-medium">{i.symbol}</span>
                  <span class="block text-[13px] text-muted">{i.exchange} · {i.currency} · {i.asset_class}</span>
                </td>
                <td class="py-2.5 pr-4 text-[13px] text-muted">
                  <span :if={i.oanda_symbol} class="block">OANDA {i.oanda_symbol}</span>
                  <span :if={i.questrade_symbol} class="block">
                    Questrade {i.questrade_symbol}<span :if={i.questrade_symbol_id}> · #{i.questrade_symbol_id}</span>
                  </span>
                  <span :if={i.massive_ticker} class="block">Massive {i.massive_ticker}</span>
                </td>
                <td class="py-2.5 text-center"><.flag_box instrument={i} flag={:active} /></td>
                <td :for={{flag, _label} <- @feeds} class="py-2.5 text-center">
                  <.flag_box instrument={i} flag={flag} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :instrument, Instrument, required: true
  attr :flag, :atom, required: true

  defp flag_box(assigns) do
    ~H"""
    <input
      type="checkbox"
      class="checkbox checkbox-sm"
      aria-label={"#{@flag} for #{@instrument.symbol}"}
      checked={Map.fetch!(@instrument, @flag)}
      phx-click="toggle"
      phx-value-id={@instrument.id}
      phx-value-flag={@flag}
    />
    """
  end
end
