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

  require Logger

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
        exposure: nil,
        questrade_connecting: false,
        questrade_notice: nil,
        # Bumped on each submit so the token field is replaced, empty.
        token_field: 0
      )

    # The broker balances take a moment (Rust asks OANDA and Questrade), so
    # the page shows straight away and fills in when they arrive, like the
    # other pages.
    {:ok,
     if(connected?(socket),
       do:
         socket
         |> start_async(:exposure, &IndexExposure.current/0)
         |> start_async(:overview, &Accounts.overview/0),
       else: socket
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(refreshing: true) |> start_async(:overview, &Accounts.refresh/0)}
  end

  # The token is a secret: it goes straight to the engine and is never
  # assigned, logged or shown. Phoenix filters any parameter named like
  # "token" out of its own event logs.
  def handle_event("connect_questrade", %{"questrade_token" => token}, socket) do
    socket = update(socket, :token_field, &(&1 + 1))

    case String.trim(token) do
      "" ->
        {:noreply,
         assign(socket, questrade_notice: {:error, "Paste the token from Questrade first."})}

      token ->
        {:noreply,
         socket
         |> assign(questrade_connecting: true, questrade_notice: nil)
         |> start_async(:questrade_connect, fn -> Client.connect_questrade(token) end)}
    end
  end

  @impl true
  def handle_async(:questrade_connect, {:ok, {:ok, %{"connected" => true}}}, socket) do
    {:noreply,
     socket
     |> assign(
       questrade_connecting: false,
       questrade_notice: {:ok, "Questrade is connected again."}
     )
     |> start_async(:overview, &Accounts.overview/0)}
  end

  def handle_async(:questrade_connect, {:ok, {:ok, answer}}, socket) do
    why = if is_binary(answer["error"]), do: " Questrade said: #{answer["error"]}", else: ""

    {:noreply,
     assign(socket,
       questrade_connecting: false,
       questrade_notice:
         {:error, "Questrade took the token but then didn't answer for the accounts.#{why}"}
     )}
  end

  def handle_async(:questrade_connect, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       questrade_connecting: false,
       questrade_notice:
         {:error,
          "That didn't connect, and nothing changed. #{describe(reason)} " <>
            "A token works only once, so generate a fresh one before trying again."}
     )}
  end

  def handle_async(:questrade_connect, {:exit, _reason}, socket) do
    # Not the reason: a crash report could carry the call's arguments.
    Logger.error("[Accounts] Connecting Questrade crashed")

    {:noreply,
     assign(socket,
       questrade_connecting: false,
       questrade_notice: {:error, "Connecting Questrade failed. Check the Opus log."}
     )}
  end

  def handle_async(:exposure, {:ok, exposure}, socket),
    do: {:noreply, assign(socket, exposure: exposure)}

  def handle_async(:exposure, {:exit, reason}, socket) do
    Logger.error("[Accounts] Index exposure crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:overview, {:ok, {:ok, overview}}, socket) do
    {:noreply,
     assign(socket,
       overview: overview,
       error: nil,
       as_of: DateTime.utc_now(),
       refreshing: false
     )}
  end

  def handle_async(:overview, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, error: describe(reason), refreshing: false)}

  def handle_async(:overview, {:exit, reason}, socket) do
    Logger.error("[Accounts] Loading balances crashed: #{inspect(reason)}")

    {:noreply,
     assign(socket, error: "Loading the balances failed. Check the Opus log.", refreshing: false)}
  end

  defp describe(reason), do: Client.describe_error(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-10">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h1 class="text-[22px] font-semibold tracking-tight"><.t {copy("Accounts")} /></h1>
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

        <p
          :if={@questrade_notice}
          role="status"
          class={[
            "rounded-box border bg-base-200 px-4 py-3 text-sm",
            if(elem(@questrade_notice, 0) == :ok,
              do: "border-primary/40",
              else: "border-error/40"
            )
          ]}
        >
          {elem(@questrade_notice, 1)}
        </p>

        <%= if @overview do %>
          <.summary overview={@overview} />
          <.exposure :if={@exposure} exposure={@exposure} />
          <.account_table accounts={@overview.accounts} />
          <.positions :for={table <- @overview.positions} table={table} />
          <p :for={broker <- @overview.offline} class="text-[13px] text-muted">
            {broker.broker} is offline{if broker.error, do: ": #{broker.error}", else: "."}
          </p>
          <.questrade_connect
            :if={questrade_offline?(@overview)}
            connecting={@questrade_connecting}
            field={@token_field}
          />
        <% else %>
          <p :if={!@error} class="text-[13px] text-muted">
            <.t {copy("Loading balances…")} />
          </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp questrade_offline?(overview), do: Enum.any?(overview.offline, &(&1.broker == "Questrade"))

  attr :connecting, :boolean, required: true
  attr :field, :integer, required: true

  # Questrade tokens work once: each connect swaps the one sent for a new
  # one the engine saves. When the saved one stops working, a fresh token
  # from Questrade gets the engine back without a restart.
  defp questrade_connect(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <span class="text-[15px] font-semibold">Paste a new Questrade token</span>
      <p class="text-[13px] text-muted">
        Questrade stopped accepting the saved token, so its balances and prices are missing.
        To get a new one: log in to Questrade, open the API centre (under your name, then
        "API centre"), find this app and choose "Generate new token". Copy it and paste it here.
        It is used once to connect and never shown or kept by Opus.
      </p>
      <form
        id="questrade-connect"
        phx-submit="connect_questrade"
        class="flex flex-wrap items-center gap-2.5"
      >
        <input
          id={"questrade-token-#{@field}"}
          type="password"
          name="questrade_token"
          autocomplete="off"
          spellcheck="false"
          placeholder="Questrade token"
          aria-label="Questrade token"
          class="input w-80 max-w-full"
        />
        <.button disabled={@connecting}>
          {if @connecting, do: "Connecting…", else: "Connect"}
        </.button>
      </form>
    </section>
    """
  end

  attr :exposure, :map, required: true

  defp exposure(assigns) do
    ~H"""
    <section class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <div class="flex flex-col gap-0.5">
        <span class="text-[13px] text-muted">
          <.t {copy("Index exposure for %{month}",
            month: Calendar.strftime(Date.shift(@exposure.month, month: 1), "%B")
          )} />
        </span>
        <span class="text-[15px]">
          {@exposure.label}: <span class="font-semibold">{pct(@exposure.exposure)}</span>
          <.t {copy("invested, the rest in cash")} />
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
        <span class="text-[13px] text-muted"><.t {copy("Everything, in CAD")} /></span>
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
        <span><.t {copy("Account")} /></span>
        <span><.t {copy("Source")} /></span>
        <span class="text-right"><.t {copy("Cash")} /></span>
        <span class="text-right"><.t {pcopy("account", "Value")} /></span>
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
      <span class="text-[15px] font-semibold">{@table.account} <.t {copy("positions")} /></span>
      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5">
        <table class="w-full min-w-[560px] border-collapse text-sm">
          <thead>
            <tr class="text-left text-xs text-muted">
              <th class="border-b border-base-300 py-2.5 font-medium">
                <.t {copy("Symbol")} />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t {copy("Shares")} />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t {copy("Avg cost")} />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t {copy("Price")} />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t {pcopy("account", "Value")} />
              </th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">
                <.t {copy("Gain")} />
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
      <span :if={@table.priced_at} class="text-[12px] text-muted">
        <.t {copy(
          "Prices from Questrade as of %{time}, refreshed every 15 minutes while the market is open.",
          time: "#{stamp(@table.priced_at)} #{zone_name(@table.priced_at)}"
        )} />
      </span>
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
