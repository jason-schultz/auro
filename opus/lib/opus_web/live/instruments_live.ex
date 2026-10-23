defmodule OpusWeb.InstrumentsLive do
  @moduledoc """
  Instruments page: the security master as a table. Search it, add a
  listing by its vendor spelling, and tick which feeds store data for it.
  The feed workers read these flags on their next run.
  """
  use OpusWeb, :live_view

  alias Opus.Instruments
  alias Opus.Instruments.Instrument

  @add_defaults %{"spelling" => "", "asset_class" => "equity"}

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

  def handle_event("enrich", _params, socket) do
    socket = assign(socket, busy: true)

    case Instruments.enrich() do
      {:ok, %{"resolved" => resolved, "failed" => failed}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Questrade identified #{resolved} listings; #{length(failed)} failed."
         )
         |> assign(busy: false)
         |> reload()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, describe(reason)) |> assign(busy: false)}
    end
  end

  defp reload(socket) do
    assign(socket, instruments: Instruments.list(search: socket.assigns.search))
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp describe({:http_error, _status, %{"error" => message}}), do: message
  defp describe({:http_error, status, _body}), do: "Auro answered with status #{status}."
  defp describe(%{reason: :econnrefused}), do: "Auro is not running."
  defp describe(_), do: "Could not reach Auro."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <header class="flex flex-col gap-1">
          <h1 class="text-[22px] font-semibold tracking-tight">Instruments</h1>
          <p class="text-[13px] text-muted">
            Every listing Auro knows, and which feeds store data for it. Changes apply on the next run.
          </p>
        </header>

        <div class="flex flex-wrap items-end gap-4">
          <form id="search-form" phx-change="search" phx-submit="search" class="grow">
            <input
              type="search"
              name="search"
              value={@search}
              placeholder="Search symbol or vendor name"
              class="input input-sm w-full max-w-xs"
              phx-debounce="200"
            />
          </form>

          <.form for={@add_form} id="add-form" phx-submit="add" class="flex items-end gap-2">
            <.input
              field={@add_form[:spelling]}
              label="Add listing"
              placeholder="RY.TO, SPY, EUR_USD"
              class="input input-sm"
            />
            <.input
              field={@add_form[:asset_class]}
              type="select"
              label="Class"
              options={@asset_classes}
              class="select select-sm"
            />
            <button type="submit" class="btn btn-sm">Add</button>
          </.form>

          <button type="button" class="btn btn-sm" phx-click="enrich" disabled={@busy}>
            {if @busy, do: "Asking Questrade…", else: "Identify via Questrade"}
          </button>
        </div>

        <p class="text-[12px] text-muted">{length(@instruments)} listings</p>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Symbol</th>
                <th>Exchange</th>
                <th>Ccy</th>
                <th>Class</th>
                <th>OANDA</th>
                <th>Questrade</th>
                <th>Massive</th>
                <th>Active</th>
                <th :for={{_flag, label} <- @feeds}>{label}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={i <- @instruments} id={"instrument-#{i.id}"}>
                <td class="font-medium">{i.symbol}</td>
                <td>{i.exchange}</td>
                <td>{i.currency}</td>
                <td>{i.asset_class}</td>
                <td class="text-muted">{i.oanda_symbol}</td>
                <td class="text-muted">
                  {i.questrade_symbol}
                  <span :if={i.questrade_symbol_id} class="text-[11px]">#{i.questrade_symbol_id}</span>
                </td>
                <td class="text-muted">{i.massive_ticker}</td>
                <td><.flag_box instrument={i} flag={:active} /></td>
                <td :for={{flag, _label} <- @feeds}><.flag_box instrument={i} flag={flag} /></td>
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
      checked={Map.fetch!(@instrument, @flag)}
      phx-click="toggle"
      phx-value-id={@instrument.id}
      phx-value-flag={@flag}
    />
    """
  end
end
