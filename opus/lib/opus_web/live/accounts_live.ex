defmodule OpusWeb.AccountsLive do
  @moduledoc """
  Accounts page: every broker account in one CAD total, an allocation bar,
  a flat account table, the hand-entered Wealthsimple positions, and this
  month's index exposure under the volatility rule.

  Balances are read from the Rust engine on mount and on Refresh; nothing
  here is pushed by price events.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Accounts
  alias Opus.Accounts.IndexExposure
  alias Opus.Auro.Client

  @impl true
  def mount(_params, _session, socket) do
    # The static render (before the websocket connects) shows the frame only;
    # the connected mount fills it in.
    socket =
      assign(socket,
        page_title: "Accounts",
        refreshing: false,
        overview: nil,
        error: nil,
        as_of: nil,
        exposure: nil
      )

    {:ok,
     if(connected?(socket),
       do: socket |> assign(exposure: IndexExposure.current()) |> load(&Accounts.overview/0),
       else: socket
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(refreshing: true) |> load(&Accounts.refresh/0)}
  end

  defp load(socket, fetch) do
    case fetch.() do
      {:ok, overview} ->
        assign(socket,
          overview: overview,
          error: nil,
          as_of: DateTime.utc_now(),
          refreshing: false
        )

      {:error, reason} ->
        assign(socket, error: describe(reason), refreshing: false)
    end
  end

  defp describe(reason), do: Client.describe_error(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-10">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h1 class="text-[22px] font-semibold tracking-tight"><.t s="Accounts" wsb="The bag" /></h1>
          <div class="flex items-baseline gap-4 text-[13px] text-muted">
            <span :if={@as_of}>Updated {clock(@as_of)}</span>
            <button
              type="button"
              phx-click="refresh"
              disabled={@refreshing}
              class="font-medium text-primary hover:brightness-110 disabled:opacity-60"
            >
              {if @refreshing, do: "Refreshing…", else: "Refresh"}
            </button>
          </div>
        </header>

        <p
          :if={@error}
          role="alert"
          class="rounded-box border border-error/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@error}
        </p>

        <%= if @overview do %>
          <.summary overview={@overview} />
          <.exposure :if={@exposure} exposure={@exposure} />
          <.account_table accounts={@overview.accounts} />
          <.positions :for={table <- @overview.positions} table={table} />
          <p :for={broker <- @overview.offline} class="text-[13px] text-muted">
            {broker.broker} is offline{if broker.error, do: ": #{broker.error}", else: "."}
          </p>
        <% else %>
          <p :if={!@error} class="text-[13px] text-muted">
            <.t s="Loading balances…" wsb="Counting tendies…" />
          </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :exposure, :map, required: true

  defp exposure(assigns) do
    ~H"""
    <section class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <div class="flex flex-col gap-0.5">
        <span class="text-[13px] text-muted">
          <.t
            s={"Index exposure for #{Calendar.strftime(Date.shift(@exposure.month, month: 1), "%B")}"}
            wsb={"How much to YOLO into the index in #{Calendar.strftime(Date.shift(@exposure.month, month: 1), "%B")}"}
          />
        </span>
        <span class="text-[15px]">
          {@exposure.label}: <span class="font-semibold">{pct(@exposure.exposure)}</span>
          <.t s="invested, the rest in cash" wsb="sent, the rest on the sidelines" />
        </span>
      </div>
      <span class="text-[13px] text-muted">
        {Calendar.strftime(@exposure.month, "%B")} volatility {pct(@exposure.realized_vol)} against a 16% target
      </span>
    </section>
    """
  end

  attr :overview, :map, required: true

  defp summary(assigns) do
    ~H"""
    <section class="flex flex-col gap-[18px]">
      <div class="flex flex-col gap-1">
        <span class="text-[13px] text-muted"><.t
          s="Everything, in CAD"
          wsb="Net worth in maple tendies (CAD)"
        /></span>
        <span class="text-5xl font-semibold leading-[1.05] tracking-tight">
          {money(@overview.total_cad)}
        </span>
      </div>
      <div aria-hidden="true" class="flex h-3.5 gap-0.5 overflow-hidden rounded-full">
        <div
          :for={account <- @overview.accounts}
          :if={account.share}
          style={"flex: #{account.share * 100} 0 0; background: #{color(account.rank)}"}
        />
      </div>
      <div class="flex flex-wrap gap-x-7 gap-y-2.5 text-[13px] text-muted">
        <span :for={account <- @overview.accounts} class="inline-flex items-center gap-2">
          <.swatch color={color(account.rank)} /> {account.label} {pct(account.share)}
        </span>
      </div>
    </section>
    """
  end

  attr :accounts, :list, required: true

  defp account_table(assigns) do
    ~H"""
    <section class="flex flex-col">
      <div class="grid grid-cols-[minmax(0,2.2fr)_minmax(0,1.2fr)_repeat(2,minmax(0,1fr))] gap-4 border-b border-base-300 pb-2.5 text-xs text-muted">
        <span><.t s="Account" wsb="Bag" /></span>
        <span><.t s="Source" wsb="Source" /></span>
        <span class="text-right"><.t s="Cash" wsb="Dry powder" /></span>
        <span class="text-right"><.t s="Value" wsb="Worth" /></span>
      </div>
      <div
        :for={account <- @accounts}
        class="grid grid-cols-[minmax(0,2.2fr)_minmax(0,1.2fr)_repeat(2,minmax(0,1fr))] items-center gap-4 border-b border-neutral py-3.5 text-[15px] last:border-b-0"
      >
        <span class="flex items-center gap-3">
          <.swatch color={color(account.rank)} /> {account.label}
          <span :if={account.number} class="text-[13px] text-muted">{account.number}</span>
        </span>
        <span class="inline-flex items-center gap-1.5 text-[13px] text-muted">
          <span
            :if={account.source == :live}
            aria-hidden="true"
            class="size-[7px] rounded-full bg-primary"
          />
          {account.broker}, {if account.source == :live, do: "live", else: "by hand"}
        </span>
        <span class={["text-right", is_nil(account.cash) && "text-muted"]}>
          {money(account.cash)}
        </span>
        <span class="text-right font-medium">
          {money(account.value)}<span
            :if={account.currency != "CAD"}
            class="ml-1 text-[13px] text-muted"
          >{account.currency}</span>
        </span>
      </div>
    </section>
    """
  end

  attr :table, :map, required: true

  defp positions(assigns) do
    ~H"""
    <section class="flex flex-col gap-3">
      <span class="text-[15px] font-semibold">{@table.account} <.t s="positions" wsb="bags" /></span>
      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5">
        <table class="w-full min-w-[560px] border-collapse text-sm">
          <thead>
            <tr class="text-left text-xs text-muted">
              <th class="border-b border-base-300 py-2.5 font-medium">
                <.t s="Symbol" wsb="Ticker" />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t s="Shares" wsb="Shares" />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t s="Avg cost" wsb="Cost basis" />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t s="Price" wsb="Price" />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t s="Value" wsb="Worth" />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t s="Gain" wsb="Tendies" />
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @table.rows}>
              <td class="py-2.5 font-medium">{row.symbol}</td>
              <td class="py-2.5 text-right">{shares(row.shares)}</td>
              <td class="py-2.5 text-right">{money(row.avg_cost)}</td>
              <td class="py-2.5 text-right">{money(row.price)}</td>
              <td class="py-2.5 text-right">{money(row.value)}</td>
              <td class={["py-2.5 text-right", tone(row.gain)]}>{money(row.gain)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # Allocation colours by value rank (largest first), taken from the active
  # theme so they follow it; the mixes fill in hues the theme doesn't name.
  @palette [
    "var(--color-primary)",
    "var(--color-secondary)",
    "var(--color-accent)",
    "color-mix(in oklab, var(--color-secondary) 50%, var(--color-error))",
    "var(--color-neutral-content)",
    "var(--color-error)",
    "color-mix(in oklab, var(--color-secondary) 60%, var(--color-base-content))",
    "color-mix(in oklab, var(--color-primary) 50%, var(--color-accent))"
  ]

  defp color(rank), do: Enum.at(@palette, rem(rank, length(@palette)))

  attr :color, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <span aria-hidden="true" class="size-2.5 rounded-[3px]" style={"background: #{@color}"} />
    """
  end
end
