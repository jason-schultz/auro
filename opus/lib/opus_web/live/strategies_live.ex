defmodule OpusWeb.StrategiesLive do
  @moduledoc """
  Live strategies monitor: one line per deployed strategy with its switch
  and a single status line (trading, held and why, suspended, or off),
  linking to the strategy's own page for everything else.

  Rows come from Opus's own tables, so the page stands without the engine;
  the live numbers on a trading row need it and are left out when it is down.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Auro.Client
  alias Opus.Trading.Strategies

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Strategies",
        rows: [],
        stats: %{},
        engine_error: nil,
        as_of: nil
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

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

    assign(socket,
      rows: Strategies.list(),
      stats: stats,
      engine_error: engine_error,
      as_of: DateTime.utc_now()
    )
  end

  defp describe(reason), do: Client.describe_error(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <div class="flex items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t s="Strategies" wsb="Plays" />
            </h1>
            <span class="text-[13px] text-muted">
              {Enum.count(@rows, & &1.enabled)} of {length(@rows)} <.t s="enabled" wsb="sending it" />
            </span>
          </div>
          <div class="flex items-baseline gap-4 text-[13px] text-muted">
            <span :if={@as_of}>Updated {clock(@as_of)}</span>
            <button
              type="button"
              phx-click="refresh"
              class="font-medium text-primary hover:brightness-110"
            >
              Refresh
            </button>
          </div>
        </header>

        <p
          :if={@engine_error}
          role="alert"
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@engine_error} Showing what Opus knows; live numbers need the engine.
        </p>

        <p :if={@as_of && @rows == []} class="text-[13px] text-muted">
          <.t s="No strategies deployed." wsb="No plays deployed. Sir, this is a Wendy's." />
        </p>

        <ul :if={@rows != []} class="m-0 flex list-none flex-col p-0">
          <li
            :for={row <- @rows}
            id={"strategy-#{row.id}"}
            class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-6 gap-y-2 border-b border-neutral py-4 last:border-b-0 sm:grid-cols-[minmax(0,5fr)_minmax(0,6fr)_auto]"
          >
            <div class="flex min-w-0 flex-col gap-0.5">
              <.link
                navigate={~p"/strategies/#{row.id}"}
                class="truncate text-[15px] font-medium hover:text-primary"
              >
                {row.name}
              </.link>
              <span class="text-[13px] text-muted">{row.instrument} · {row.granularity}</span>
            </div>
            <div class="order-last col-span-2 flex min-w-0 flex-col gap-0.5 sm:order-none sm:col-span-1">
              <.status row={row} stats={@stats[row.id]} />
            </div>
            <.switch row={row} />
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :stats, :map, default: nil

  defp status(%{row: %{suspension: suspension}} = assigns) when not is_nil(suspension) do
    ~H"""
    <span class="text-[14px] font-medium text-error"><.t s="Suspended" wsb="In timeout" /></span>
    <span class="text-[13px] text-muted">
      {@row.suspension.trigger_detail} ·
      <button
        type="button"
        phx-click="reset"
        phx-value-id={@row.id}
        class="font-medium text-primary hover:brightness-110"
      >
        <.t s="Reset" wsb="Un-bench" />
      </button>
    </span>
    """
  end

  defp status(%{row: %{enabled: false}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-muted"><.t s="Off" wsb="Benched" /></span>
    <span class="text-[13px] text-muted">{curator(@row.curator_mode)}</span>
    """
  end

  defp status(%{row: %{rule: nil}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium"><.t s="On, no decision yet" wsb="On, jury's out" /></span>
    <span class="text-[13px] text-muted">{curator(@row.curator_mode)}</span>
    """
  end

  defp status(%{row: %{rule: %{enabled: true}}} = assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-success">
      <.t s="Trading" wsb="Sending it" /><span
        :if={@row.open_trades > 0}
        class="font-normal text-base-content"
      > · {@row.open_trades} open</span>
    </span>
    <span class="text-[13px] text-muted">
      <.t s={live_line(@stats, @row, :serious)} wsb={live_line(@stats, @row, :wsb)} />
    </span>
    """
  end

  defp status(assigns) do
    ~H"""
    <span class="text-[14px] font-medium text-warning"><.t s="Held" wsb="Hands tied" /></span>
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
      <.t :if={@row.enabled} s="Enabled" wsb="Sending it" />
      <.t :if={!@row.enabled} s="Disabled" wsb="Benched" />
    </button>
    """
  end

  defp live_line(%{live: %{"num_trades" => n} = live}, _row, voice)
       when is_integer(n) and n > 0 do
    noun = if voice == :wsb, do: "plays", else: "live trades"
    hit = if voice == :wsb, do: "hit", else: "win"
    "#{n} #{noun} · #{pct(live["win_rate"])} #{hit} · #{signed_pct(live["total_return"])}"
  end

  defp live_line(_stats, %{last_signal: %{action: action, at: at}}, voice) do
    verb = if voice == :wsb, do: "last move", else: "last signal"
    "#{verb} #{String.replace(action, "_", " ")} · #{stamp(at)}"
  end

  defp live_line(_stats, _row, :wsb), do: "no plays yet, positions or ban"
  defp live_line(_stats, _row, _voice), do: "no trades yet"

  defp curator("auto"), do: "curator decides"
  defp curator("pinned_on"), do: "pinned on by hand"
  defp curator("pinned_off"), do: "pinned off by hand"
  defp curator(other), do: other
end
