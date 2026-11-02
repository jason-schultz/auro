defmodule OpusWeb.AccountsLive do
  @moduledoc """
  Accounts page: every broker account in one CAD total, an allocation bar,
  a flat account table, the hand-entered Wealthsimple positions (edited
  here: `Opus.Accounts.Holdings`), and this month's index exposure under
  the volatility rule.

  Balances are read from the Rust engine on mount and on Refresh; nothing
  here is pushed by price events.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.Components.ValueLine

  require Logger

  alias Opus.Accounts
  alias Opus.Accounts.{Holdings, Snapshots}
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
        # The holdings editor: nil when closed, else the draft being edited.
        draft: nil,
        draft_error: nil,
        saving: false,
        history: [],
        net_worth: [],
        paper_line: []
      )

    # The broker balances take a moment (Rust asks OANDA and Questrade), so
    # the page shows straight away and fills in when they arrive, like the
    # other pages.
    {:ok,
     if(connected?(socket),
       do:
         socket
         |> assign(
           history: Snapshots.history(90),
           net_worth: Snapshots.net_worth(365),
           paper_line: Opus.Journal.nav_by_day()
         )
         |> start_async(:exposure, &IndexExposure.current/0)
         |> start_async(:overview, &Accounts.overview/0),
       else: socket
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(refreshing: true) |> start_async(:overview, &Accounts.refresh/0)}
  end

  # Wealthsimple has no API: its accounts and holdings are typed in here.
  def handle_event("edit_holdings", _params, socket) do
    case Client.wealthsimple_accounts() do
      {:ok, stored} -> {:noreply, assign(socket, draft: Holdings.draft(stored), draft_error: nil)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  def handle_event("holdings_change", params, socket),
    do: {:noreply, assign(socket, draft: Holdings.from_params(params), draft_error: nil)}

  def handle_event("add_account", _params, socket),
    do: {:noreply, update(socket, :draft, &(&1 ++ [Holdings.blank_account()]))}

  def handle_event("remove_account", %{"account" => i}, socket),
    do: {:noreply, update(socket, :draft, &List.delete_at(&1, String.to_integer(i)))}

  def handle_event("add_position", %{"account" => i}, socket) do
    {:noreply,
     update(socket, :draft, fn draft ->
       List.update_at(draft, String.to_integer(i), fn a ->
         Map.update!(a, "positions", &(&1 ++ [Holdings.blank_position()]))
       end)
     end)}
  end

  def handle_event("remove_position", %{"account" => i, "position" => j}, socket) do
    {:noreply,
     update(socket, :draft, fn draft ->
       List.update_at(draft, String.to_integer(i), fn a ->
         Map.update!(a, "positions", &List.delete_at(&1, String.to_integer(j)))
       end)
     end)}
  end

  def handle_event("cancel_holdings", _params, socket),
    do: {:noreply, assign(socket, draft: nil, draft_error: nil)}

  def handle_event("save_holdings", params, socket) do
    draft = Holdings.from_params(params)

    {:noreply,
     socket
     |> assign(draft: draft, saving: true)
     |> start_async(:save_holdings, fn -> Accounts.save_holdings(draft) end)}
  end

  @impl true
  def handle_async(:exposure, {:ok, exposure}, socket),
    do: {:noreply, assign(socket, exposure: exposure)}

  def handle_async(:exposure, {:exit, reason}, socket) do
    Logger.error("[Accounts] Index exposure crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:save_holdings, {:ok, {:ok, overview, added}}, socket) do
    {:noreply,
     socket
     |> assign(overview: overview, as_of: DateTime.utc_now(), draft: nil, saving: false)
     |> put_flash(:info, saved_words(added))}
  end

  def handle_async(:save_holdings, {:ok, {:error, words}}, socket) when is_binary(words),
    do: {:noreply, assign(socket, draft_error: words, saving: false)}

  def handle_async(:save_holdings, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, draft_error: describe(reason), saving: false)}

  def handle_async(:save_holdings, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, draft_error: "Saving didn't finish. Check the Opus log.", saving: false)}

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

  defp saved_words([]), do: "Holdings saved."

  defp saved_words(added),
    do:
      "Holdings saved. Added #{Enum.join(added, ", ")} to the instruments as " <>
        "#{if length(added) == 1, do: "a stock", else: "stocks"} (change it on the Instruments " <>
        "page if it's an ETF); its prices, history and dividends load from now."

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

        <%= if @overview do %>
          <.summary overview={@overview} />
          <section class="flex flex-col gap-3">
            <span class="text-[15px] font-semibold"><.t {copy("Net worth over time")} /></span>
            <span class="text-[13px] text-muted">Real money only, at each trading day's close.</span>
            <.value_line
              id="net-worth"
              points={@net_worth}
              label="Net worth (CAD)"
              empty="Every real account's value is recorded at each trading day's close (4:10 PM New York); the line shows here from the second close. CAD accounts, as the total above; paper accounts and the paper options books aren't counted."
            />
          </section>
          <section :if={@overview.paper_cad > 0} class="flex flex-col gap-3">
            <span class="text-[15px] font-semibold"><.t {copy("Paper money over time")} /></span>
            <span class="text-[13px] text-muted">
              OANDA's practice account, valued at each day's last snapshot. Practice money, kept apart from net worth.
            </span>
            <.value_line id="paper-worth" points={@paper_line} label="OANDA practice account (CAD)" />
          </section>
          <.exposure :if={@exposure} exposure={@exposure} />
          <.account_table accounts={@overview.accounts} />
          <div :if={is_nil(@draft)} class="flex flex-col gap-3">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span class="text-[15px] font-semibold">
                <.t {copy("Wealthsimple, entered by hand")} />
              </span>
              <button
                type="button"
                phx-click="edit_holdings"
                class="min-h-11 rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary"
              >
                <.t {copy("Edit accounts and holdings")} />
              </button>
            </div>
            <.positions :for={table <- @overview.positions} table={table} />
            <.holdings_history history={@history} />
          </div>
          <.holdings_editor :if={@draft} draft={@draft} error={@draft_error} saving={@saving} />
          <p :for={broker <- @overview.offline} class="text-[13px] text-muted">
            {broker.broker} is offline{if broker.error, do: ": #{broker.error}", else: "."}
            <.link
              :if={broker.broker == "Questrade"}
              navigate={~p"/settings/integrations/questrade"}
              class="font-medium text-primary hover:brightness-110"
            >
              Reconnect it on Settings
            </.link>
          </p>
        <% else %>
          <p :if={!@error} class="text-[13px] text-muted">
            <.t {copy("Loading balances…")} />
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
        <span :if={@overview.paper_cad > 0} class="text-[13px] text-muted">
          Real money only. Paper (practice) accounts: {money(@overview.paper_cad)}, not counted.
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
        <span
          :for={account <- @overview.accounts}
          :if={not account.paper}
          class="inline-flex items-center gap-2"
        >
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
          <.paper_tag :if={account.paper} />
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

  attr :draft, :list, required: true
  attr :error, :string, default: nil
  attr :saving, :boolean, default: false

  defp holdings_editor(assigns) do
    ~H"""
    <form
      id="holdings-form"
      phx-change="holdings_change"
      phx-submit="save_holdings"
      class="flex flex-col gap-4 rounded-box border border-primary/40 bg-base-200 px-5 py-4"
    >
      <div class="flex flex-col gap-1">
        <span class="text-[15px] font-semibold"><.t {copy("Wealthsimple accounts and holdings")} /></span>
        <span class="text-[13px] text-muted">
          Wealthsimple has no API, so these are typed in. List each holding with its shares and
          average cost; prices come from Questrade every 15 minutes. For an account you don't list
          holdings for (a managed portfolio), type its holdings value instead.
        </span>
      </div>

      <fieldset
        :for={{account, i} <- Enum.with_index(@draft)}
        class="flex flex-col gap-3 rounded-field border border-base-300 bg-base-100 px-4 py-3"
      >
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-[9rem_10rem_6rem_1fr_1fr_auto] sm:items-end">
          <label class="flex flex-col gap-1 text-[12px] text-muted">
            Type
            <select name={"accounts[#{i}][account_type]"} class="select select-sm">
              <option
                :for={t <- Holdings.account_types()}
                value={t}
                selected={t == account["account_type"]}
              >
                {t}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-[12px] text-muted">
            Number (optional)
            <input
              name={"accounts[#{i}][account_number]"}
              value={account["account_number"]}
              class="input input-sm"
            />
          </label>
          <label class="flex flex-col gap-1 text-[12px] text-muted">
            Currency
            <select name={"accounts[#{i}][currency]"} class="select select-sm">
              <option :for={c <- Holdings.currencies()} value={c} selected={c == account["currency"]}>
                {c}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-[12px] text-muted">
            Cash
            <input
              name={"accounts[#{i}][cash]"}
              value={account["cash"]}
              inputmode="decimal"
              placeholder="0.00"
              class="input input-sm"
            />
          </label>
          <label :if={account["positions"] == []} class="flex flex-col gap-1 text-[12px] text-muted">
            Holdings value
            <input
              name={"accounts[#{i}][market_value]"}
              value={account["market_value"]}
              inputmode="decimal"
              placeholder="0.00"
              class="input input-sm"
            />
          </label>
          <span :if={account["positions"] != []} class="text-[12px] text-muted">
            Value: cash plus the holdings below at their latest price
          </span>
          <button
            type="button"
            phx-click="remove_account"
            phx-value-account={i}
            class="min-h-9 text-[12px] text-error hover:underline"
          >
            Remove account
          </button>
        </div>

        <div :if={account["positions"] != []} class="flex flex-col gap-2">
          <div
            :for={{p, j} <- Enum.with_index(account["positions"])}
            class="grid grid-cols-[1fr_1fr_1fr_auto] items-end gap-2"
          >
            <label class="flex flex-col gap-1 text-[12px] text-muted">
              Symbol
              <input
                name={"accounts[#{i}][positions][#{j}][symbol]"}
                value={p["symbol"]}
                placeholder="FLT.TO"
                class="input input-sm uppercase"
              />
            </label>
            <label class="flex flex-col gap-1 text-[12px] text-muted">
              Shares
              <input
                name={"accounts[#{i}][positions][#{j}][shares]"}
                value={p["shares"]}
                inputmode="decimal"
                class="input input-sm"
              />
            </label>
            <label class="flex flex-col gap-1 text-[12px] text-muted">
              Avg cost
              <input
                name={"accounts[#{i}][positions][#{j}][avg_cost]"}
                value={p["avg_cost"]}
                inputmode="decimal"
                class="input input-sm"
              />
            </label>
            <button
              type="button"
              phx-click="remove_position"
              phx-value-account={i}
              phx-value-position={j}
              aria-label={"Remove #{p["symbol"]}"}
              class="min-h-9 px-2 text-[12px] text-error hover:underline"
            >
              Remove
            </button>
          </div>
        </div>
        <button
          type="button"
          phx-click="add_position"
          phx-value-account={i}
          class="self-start text-[13px] font-medium text-primary hover:underline"
        >
          + Add a holding
        </button>
      </fieldset>

      <button
        type="button"
        phx-click="add_account"
        class="self-start text-[13px] font-medium text-primary hover:underline"
      >
        + Add an account
      </button>

      <p :if={@error} role="alert" class="m-0 text-[13px] text-error">{@error}</p>

      <div class="flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={@saving}
          class="min-h-11 rounded-field bg-primary px-4 text-[14px] font-semibold text-primary-content hover:brightness-110 disabled:opacity-50"
        >
          {if @saving, do: "Saving…", else: "Save"}
        </button>
        <button
          type="button"
          phx-click="cancel_holdings"
          class="min-h-11 rounded-field border border-base-300 px-4 text-[14px] hover:border-primary"
        >
          Cancel
        </button>
      </div>
    </form>
    """
  end

  attr :history, :list, required: true

  # The listed holdings at each close (`Opus.Accounts.Snapshots`): where
  # they stand against their high, and the last few closes.
  defp holdings_history(assigns) do
    assigns = assign(assigns, summary: Snapshots.summary(assigns.history))

    ~H"""
    <section class="flex flex-col gap-3">
      <span class="text-[15px] font-semibold"><.t {copy("Holdings over time")} /></span>
      <p :if={is_nil(@summary)} class="m-0 text-[13px] text-muted">
        The holdings are recorded at each trading day's close (4:10 PM New York). Their history,
        day's move and worst drop show here once there are two closes.
      </p>
      <div :if={@summary} class="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <div class="flex flex-col gap-0.5">
          <span class="text-[12px] text-muted">Value at {day(@summary.on)}'s close</span>
          <span class="text-[15px] font-semibold">{money(@summary.value)}</span>
        </div>
        <div class="flex flex-col gap-0.5">
          <span class="text-[12px] text-muted">That day</span>
          <span class={["text-[15px] font-semibold", tone(@summary.day_change)]}>
            {signed_money(@summary.day_change)} ({signed_pct(@summary.day_pct)})
          </span>
        </div>
        <div class="flex flex-col gap-0.5">
          <span class="text-[12px] text-muted">Below its high</span>
          <span class="text-[15px] font-semibold">{pct(@summary.drawdown)}</span>
        </div>
        <div class="flex flex-col gap-0.5">
          <span class="text-[12px] text-muted">Worst drop, last 90 days</span>
          <span class="text-[15px] font-semibold">{pct(@summary.worst_drawdown)}</span>
        </div>
      </div>
      <div
        :if={@summary}
        class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5"
      >
        <table class="w-full border-collapse text-sm">
          <thead>
            <tr class="text-left text-xs text-muted">
              <th class="border-b border-base-300 py-2.5 font-medium">Close</th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">Value</th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">Change</th>
              <th class="border-b border-base-300 py-2.5 text-right font-medium">Against cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{row, change} <- recent_closes(@history)}>
              <td class="py-2.5">{day(row.on)}</td>
              <td class="py-2.5 text-right">{money(row.value)}</td>
              <td class={["py-2.5 text-right", tone(change)]}>{signed_money(change)}</td>
              <td class={["py-2.5 text-right", tone(row.value - row.cost)]}>
                {signed_money(row.value - row.cost)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # The last ten closes, newest first, each with its change on the one before.
  defp recent_closes(history) do
    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [before, row] -> {row, row.value - before.value} end)
    |> Enum.reverse()
    |> Enum.take(10)
  end
end
