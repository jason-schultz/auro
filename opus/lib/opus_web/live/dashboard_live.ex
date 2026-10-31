defmodule OpusWeb.DashboardLive do
  @moduledoc """
  The home page: what needs the user now (share alerts to place and log,
  `Opus.Trading.ShareAlerts`, then `Opus.Dashboard.Alerts`, most urgent
  first, each with what to do), one tile each for live trading, the
  paper options books, the accounts and this month's index exposure, and
  what the paper books did at their latest check.

  Gathers once when it opens, then shows each fresh gather that
  `Opus.Dashboard.Feed` pushes when something on it changes. Broker
  balances are slow, so the Accounts tile starts from the last total
  fetched (kept between visits) and asks the brokers again only when that
  is more than five minutes old as an update lands, or on Refresh.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.Components.PaperParts, only: [book_name: 1]

  alias Opus.{Accounts, Dashboard}
  alias Opus.Dashboard.{Alerts, Feed}
  alias Opus.Trading.ShareAlerts

  # The most urgent alerts shown; the rest fold behind "N more".
  @shown_alerts 3

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Dashboard",
        data: nil,
        alerts: [],
        as_of: nil,
        fetching: false,
        shown_alerts: @shown_alerts,
        share_alerts: ShareAlerts.open(),
        logging: nil
      )
      |> assign_cached_accounts()

    if connected?(socket), do: Feed.subscribe()
    {:ok, if(connected?(socket), do: refresh(socket, :if_stale), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket, :always)}

  def handle_event("clear_job", %{"worker" => worker}, socket) do
    Dashboard.clear_failed_jobs(worker)
    {:noreply, refresh(socket, :always)}
  end

  # Log trade: the form opens filled in from the alert; you pick the
  # account and when it filled.
  def handle_event("log_trade", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.share_alerts, &(to_string(&1.alert.id) == id)) do
      nil ->
        {:noreply, socket}

      %{alert: alert} = item ->
        accounts =
          case Accounts.wealthsimple_account_types() do
            {:ok, types} -> types
            {:error, _} -> []
          end

        {:noreply,
         assign(socket,
           logging: %{
             item: item,
             accounts: accounts,
             form: to_form(ShareAlerts.form_defaults(alert, accounts), as: :fill),
             error:
               if(accounts == [],
                 do: "The accounts can't be read right now (is the engine running?).",
                 else: nil
               )
           }
         )}
    end
  end

  def handle_event("change_log", %{"fill" => params} = event, socket) do
    %{logging: logging} = socket.assigns

    {:noreply,
     assign(socket,
       logging: %{logging | form: to_form(recash(params, event, logging), as: :fill)}
     )}
  end

  def handle_event("save_log", %{"fill" => params}, socket) do
    %{logging: %{item: %{alert: alert}} = logging} = socket.assigns

    case ShareAlerts.log_fill(alert.id, params) do
      {:ok, _alert} ->
        {:noreply,
         socket
         |> assign(logging: nil, share_alerts: ShareAlerts.open())
         |> put_flash(:info, "Logged. The holdings and cash on the Accounts page include it.")}

      {:error, words} ->
        {:noreply,
         assign(socket, logging: %{logging | form: to_form(params, as: :fill), error: words})}
    end
  end

  def handle_event("close_log", _params, socket), do: {:noreply, assign(socket, logging: nil)}

  def handle_event("skip_alert", %{"id" => id}, socket) do
    _ = ShareAlerts.skip(String.to_integer(id))
    {:noreply, assign(socket, share_alerts: ShareAlerts.open())}
  end

  # A fresh gather from the feed: show it, and fetch the broker balances if
  # they've gone stale.
  @impl true
  def handle_info({:dashboard, data}, socket) do
    {:noreply,
     socket
     |> assign(data: data, as_of: DateTime.utc_now(), share_alerts: ShareAlerts.open())
     |> assign_alerts()
     |> accounts(:if_stale)}
  end

  defp assign_cached_accounts(socket) do
    case Dashboard.cached_accounts() do
      {overview, _at} ->
        assign(socket, accounts: {:ok, overview.total_cad}, offline: overview.offline)

      nil ->
        assign(socket, accounts: :loading, offline: [])
    end
  end

  @impl true
  def handle_async(:gather, {:ok, data}, socket) do
    {:noreply, socket |> assign(data: data, as_of: DateTime.utc_now()) |> assign_alerts()}
  end

  def handle_async(:gather, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:accounts, {:ok, {:ok, overview}}, socket) do
    {:noreply,
     socket
     |> assign(accounts: {:ok, overview.total_cad}, offline: overview.offline, fetching: false)
     |> assign_alerts()}
  end

  # A failed refresh keeps the last good total rather than blanking the tile.
  def handle_async(:accounts, _result, %{assigns: %{accounts: {:ok, _}}} = socket),
    do: {:noreply, assign(socket, fetching: false)}

  def handle_async(:accounts, _result, socket) do
    {:noreply, assign(socket, accounts: :unavailable, fetching: false)}
  end

  # Shares or price changed: the cash change follows them, until you type
  # the cash yourself (a conversion Wealthsimple charged).
  defp recash(params, %{"_target" => ["fill", field]}, %{item: %{alert: alert}})
       when field in ~w(shares price) do
    with {shares, ""} <- Float.parse(params["shares"] || ""),
         {price, ""} <- Float.parse(params["price"] || "") do
      Map.put(params, "cash", to_string(ShareAlerts.cash_change(alert.side, shares, price)))
    else
      _ -> params
    end
  end

  defp recash(params, _event, _logging), do: params

  # Gathering reads the engine and the database, so it runs in the
  # background: the page renders at once (with the last data, if any) and
  # fills in when the gather lands, instead of holding up navigation.
  defp refresh(socket, when_accounts) do
    socket
    |> start_async(:gather, &Dashboard.gather/0)
    |> accounts(when_accounts)
  end

  # One broker fetch at a time: updates can land faster than the brokers
  # answer, and a second start would replace the first before it finished.
  defp accounts(%{assigns: %{fetching: true}} = socket, _when), do: socket

  defp accounts(socket, when_accounts) do
    if when_accounts == :always or not Dashboard.fresh?(Dashboard.cached_accounts()),
      do: socket |> assign(fetching: true) |> start_async(:accounts, &Dashboard.accounts/0),
      else: socket
  end

  defp assign_alerts(%{assigns: %{data: nil}} = socket), do: socket

  defp assign_alerts(%{assigns: %{data: data, offline: offline}} = socket),
    do:
      assign(socket,
        alerts: data.input |> Dashboard.alerts(offline) |> Enum.filter(&Alerts.on_dashboard?/1)
      )

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        urgent: Enum.filter(assigns.alerts, &(&1.level in [:act, :check])),
        waiting: length(assigns.share_alerts),
        fyi: Enum.filter(assigns.alerts, &(&1.level == :fyi))
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <div class="flex flex-wrap items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t {copy("Dashboard")} />
            </h1>
            <span :if={@data} class={["text-[14px] font-medium", status_tone(@urgent, @waiting)]}>
              <.t {status_line(length(@urgent) + @waiting)} />
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

        <p :if={@data == nil} class="text-[13px] text-muted">
          <.t {copy("Checking everything…")} />
        </p>

        <%= if @data do %>
          <section aria-label="Needs you" class="flex flex-col gap-3">
            <span class="text-[15px] font-semibold">
              <.t {copy("Needs you")} />
            </span>
            <.share_alert_card :for={item <- @share_alerts} item={item} />
            <p
              :if={@urgent == [] and @share_alerts == []}
              class="rounded-box border border-success/40 bg-base-200 px-5 py-4 text-[14px]"
            >
              <.t {copy("Nothing needs you.")} />
            </p>
            <div :if={@urgent != []} class="flex flex-col gap-1.5">
              <.alert_card :for={alert <- Enum.take(@urgent, @shown_alerts)} alert={alert} />
              <details :if={length(@urgent) > @shown_alerts} class="group flex flex-col gap-1.5">
                <summary class="cursor-pointer list-none text-[13px] font-medium text-primary hover:brightness-110">
                  <span class="group-open:hidden">{length(@urgent) - @shown_alerts} more</span>
                  <span class="hidden group-open:inline">Show fewer</span>
                </summary>
                <div class="mt-1.5 flex flex-col gap-1.5">
                  <.alert_card :for={alert <- Enum.drop(@urgent, @shown_alerts)} alert={alert} />
                </div>
              </details>
            </div>
          </section>

          <section aria-label="Overview" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.live_tile live={@data.live} />
            <.paper_tile books={@data.books} />
            <.accounts_tile accounts={@accounts} />
            <.exposure_tile exposure={@data.exposure} />
          </section>

          <section aria-label="Open positions" class="flex flex-col gap-3">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span class="text-[15px] font-semibold">
                <.t {copy("Open positions")} />
              </span>
              <span class="text-[13px] text-muted">
                Live and paper. Click one for the details.
              </span>
            </div>
            <.positions_table positions={@data.positions} today={Opus.Clock.today()} />
          </section>

          <section :if={@fyi != []} aria-label="What happened" class="flex flex-col gap-2">
            <span class="text-[15px] font-semibold">
              <.t {copy("What happened")} />
            </span>
            <ul class="m-0 flex list-none flex-col gap-1 p-0 text-[13px]">
              <li :for={item <- @fyi} class="flex flex-wrap justify-between gap-x-4">
                <.link :if={item.link} navigate={item.link} class="hover:text-primary">
                  {item.title}
                </.link>
                <span :if={!item.link}>{item.title}</span>
                <span :if={item.detail} class="text-muted">{item.detail}</span>
              </li>
            </ul>
          </section>
        <% end %>
      </div>
      <.log_trade :if={@logging} logging={@logging} />
    </Layouts.app>
    """
  end

  attr :positions, :list, required: true
  attr :today, Date, required: true

  defp positions_table(assigns) do
    ~H"""
    <p :if={@positions == []} class="text-[13px] text-muted">
      <.t {copy("Nothing open.")} />
    </p>
    <div
      :if={@positions != []}
      class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5"
    >
      <table class="w-full min-w-[640px] border-collapse text-sm">
        <thead>
          <tr class="text-left text-xs text-muted">
            <th class="border-b border-base-300 py-2.5 font-medium">Position</th>
            <th class="border-b border-base-300 py-2.5 font-medium">Book</th>
            <th class="border-b border-base-300 py-2.5 font-medium">Opened</th>
            <th class="border-b border-base-300 py-2.5 text-right font-medium">
              <.t {copy("P&L so far")} />
            </th>
            <th class="border-b border-base-300 py-2.5 pl-6 font-medium">Next decision</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @positions} class="border-b border-neutral last:border-b-0">
            <td class="py-2.5">
              <.link navigate={p.link} class="hover:text-primary">{p.label}</.link>
              <span
                :if={p.opened_on == @today}
                class="ml-1.5 rounded-full bg-primary/15 px-1.5 py-0.5 text-[11px] text-primary"
              >
                new
              </span>
            </td>
            <td class="py-2.5 text-muted">
              <.t {book_label(p.book)} />
            </td>
            <td class="py-2.5 text-muted">{day(p.opened_on)}</td>
            <td class={["py-2.5 text-right", tone(p.pnl)]}>{signed_money(p.pnl)}</td>
            <td class="py-2.5 pl-6 text-muted">{next_decision(p)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp book_label("live"), do: copy("Live (OANDA)")
  defp book_label(book), do: book_name(book)

  defp next_decision(%{book: "live", stop_loss_price: stop}) when is_number(stop),
    do: "The engine closes it; stop at #{num(stop)}"

  defp next_decision(%{book: "live"}), do: "The engine closes it"
  defp next_decision(%{manage_on: %Date{} = on}), do: "21-day check, #{day(on)}"
  defp next_decision(%{expiration: %Date{} = on}), do: "Expires #{day(on)}"
  defp next_decision(_position), do: "—"

  attr :alert, :map, required: true

  # One line each (level, title, Open), the detail and what to do folded
  # away underneath, so many alerts don't push the page down.
  defp alert_card(assigns) do
    ~H"""
    <details class={[
      "group rounded-box border bg-base-200 px-4 py-2.5",
      if(@alert.level == :act, do: "border-error/50", else: "border-warning/50")
    ]}>
      <summary class="flex cursor-pointer list-none flex-wrap items-baseline gap-x-3 gap-y-1">
        <span class={[
          "text-[12px] font-medium",
          if(@alert.level == :act, do: "text-error", else: "text-warning")
        ]}>
          <.t :if={@alert.level == :act} {copy("Act now")} />
          <.t :if={@alert.level == :check} {copy("Check soon")} />
        </span>
        <span class="min-w-0 flex-1 text-[14px] font-semibold">{@alert.title}</span>
        <span class="text-[12px] text-muted group-open:hidden">Details ▸</span>
        <span class="hidden text-[12px] text-muted group-open:inline">▾</span>
      </summary>
      <div class="mt-2 flex flex-col gap-1.5">
        <p :if={@alert.detail} class="text-[13px] text-muted">{@alert.detail}</p>
        <p class="text-[13px]">
          <span class="font-medium"><.t {copy("What to do:")} /></span>
          {@alert.what_to_do}
        </p>
        <.link
          :if={@alert.link}
          navigate={@alert.link}
          class="self-start text-[13px] font-medium text-primary hover:brightness-110"
        >
          Open →
        </.link>
        <button
          :if={@alert[:clear_worker]}
          type="button"
          phx-click="clear_job"
          phx-value-worker={@alert.clear_worker}
          class="min-h-9 self-start text-[13px] font-medium text-primary hover:brightness-110"
        >
          <.t {copy("Clear")} />
        </button>
      </div>
    </details>
    """
  end

  attr :item, :map, required: true

  # A share alert stays here until you log it or say you didn't trade.
  defp share_alert_card(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-box border border-primary/50 bg-base-200 px-4 py-2.5">
      <span class="text-[12px] font-medium text-primary">
        <.t {copy("Share alert")} /> · {day(@item.alert.day)}
      </span>
      <span class="min-w-0 flex-1 text-[14px] font-semibold">
        {ShareAlerts.line(@item.alert, @item.name)}
      </span>
      <div class="flex gap-3">
        <button
          type="button"
          phx-click="log_trade"
          phx-value-id={@item.alert.id}
          class="btn btn-primary btn-sm"
        >
          <.t {copy("Log trade")} />
        </button>
        <button
          type="button"
          phx-click="skip_alert"
          phx-value-id={@item.alert.id}
          class="min-h-9 text-[13px] font-medium text-muted hover:text-base-content"
        >
          <.t {copy("Didn't trade")} />
        </button>
      </div>
    </div>
    """
  end

  attr :logging, :map, required: true

  defp log_trade(assigns) do
    ~H"""
    <div class="modal modal-open" role="dialog" aria-modal="true" aria-labelledby="log-trade-title">
      <div class="modal-box flex max-w-md flex-col gap-3">
        <h2 id="log-trade-title" class="text-[17px] font-semibold">
          <.t {copy("Log trade")} />: {String.upcase(@logging.item.alert.side)} {@logging.item.alert.symbol}
        </h2>
        <p class="text-[13px] text-muted">
          Filled in from the alert. Pick the account, and change anything your fill did differently.
        </p>
        <.form
          for={@logging.form}
          id="log-trade-form"
          phx-change="change_log"
          phx-submit="save_log"
          class="flex flex-col gap-1"
        >
          <.input
            type="select"
            field={@logging.form[:account]}
            label="Account it was filled in"
            prompt="Pick one"
            options={@logging.accounts}
          />
          <div class="grid grid-cols-2 gap-3">
            <.input field={@logging.form[:shares]} label="Shares" inputmode="decimal" />
            <.input field={@logging.form[:price]} label="Price per share" inputmode="decimal" />
          </div>
          <.input type="datetime-local" field={@logging.form[:filled_at]} label="When it filled" />
          <.input
            field={@logging.form[:cash]}
            label="Cash change in the account (minus: spent)"
            inputmode="decimal"
          />
          <p class="text-[12px] text-muted">
            If Wealthsimple converted currency, put the amount it actually took or paid.
          </p>
          <p :if={@logging.error} class="text-[13px] text-error">{@logging.error}</p>
          <div class="mt-2 flex justify-end gap-3">
            <button type="button" phx-click="close_log" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
              <.t {copy("Save")} />
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_log"></div>
    </div>
    """
  end

  attr :live, :map, required: true

  defp live_tile(assigns) do
    ~H"""
    <.tile title={copy("Live trading")} link={~p"/strategies"}>
      <span class="text-[22px] font-semibold">{money(@live.nav)}</span>
      <span class={["text-[13px]", tone(@live.nav_change)]}>
        {signed_money(@live.nav_change)} today
      </span>
      <span class="text-[13px] text-muted">
        OANDA practice · {@live.open_trades} open {if @live.open_trades == 1,
          do: "trade",
          else: "trades"}
      </span>
      <span class={["text-[13px]", if(@live.engine_up, do: "text-success", else: "text-error")]}>
        {if @live.engine_up, do: "Engine running", else: "Engine not reachable"}
      </span>
    </.tile>
    """
  end

  attr :books, :list, required: true

  defp paper_tile(assigns) do
    ~H"""
    <.tile title={copy("Paper options")} link={~p"/options?view=paper"}>
      <ul class="m-0 flex list-none flex-col gap-1 p-0 text-[13px]">
        <li :for={book <- @books} class="flex items-baseline justify-between gap-3">
          <.link navigate={book.link} class="relative z-10 min-w-0 truncate hover:text-primary">
            <.t {book_name(book.book)} />
            <span :if={book.open > 0} class="text-muted">· {book.open} open</span>
          </.link>
          <span :if={book.started} class={["shrink-0 whitespace-nowrap", tone(book.pnl)]}>
            {signed_money(book.pnl)}
          </span>
          <span :if={!book.started} class="shrink-0 whitespace-nowrap text-muted">not started</span>
        </li>
      </ul>
    </.tile>
    """
  end

  attr :accounts, :any, required: true

  defp accounts_tile(assigns) do
    ~H"""
    <.tile title={copy("Accounts")} link={~p"/accounts"}>
      <%= case @accounts do %>
        <% {:ok, total} -> %>
          <span class="text-[22px] font-semibold">{money(total)}</span>
          <span class="text-[13px] text-muted">everything, in CAD</span>
        <% :loading -> %>
          <span class="text-[22px] font-semibold text-muted">—</span>
          <span class="text-[13px] text-muted">asking the brokers…</span>
        <% _ -> %>
          <span class="text-[22px] font-semibold text-muted">—</span>
          <span class="text-[13px] text-muted">balances unavailable right now</span>
      <% end %>
    </.tile>
    """
  end

  attr :exposure, :map, default: nil

  defp exposure_tile(assigns) do
    ~H"""
    <.tile title={copy("Index exposure")} link={~p"/accounts"}>
      <%= if @exposure do %>
        <span class="text-[22px] font-semibold">{pct(@exposure.exposure)}</span>
        <span class="text-[13px] text-muted">
          of your S&P 500 holdings this month; last month's volatility {pct(@exposure.realized_vol)}
        </span>
      <% else %>
        <span class="text-[22px] font-semibold text-muted">—</span>
        <span class="text-[13px] text-muted">no S&P bars for last month</span>
      <% end %>
    </.tile>
    """
  end

  attr :title, :map, required: true, doc: "copy/1"
  attr :link, :string, required: true
  slot :inner_block, required: true

  # The whole card is clickable through its title link's stretched ::after
  # overlay, not by wrapping the card in a link: a card can then hold links
  # of its own (raised above the overlay), which a link inside a link would
  # break — the browser ends the outer link early and spills the rest out.
  defp tile(assigns) do
    ~H"""
    <div class="relative flex flex-col gap-1 rounded-box border border-base-300 bg-base-200 px-5 py-4 hover:border-primary">
      <.link navigate={@link} class="text-[12px] text-muted after:absolute after:inset-0">
        <.t {@title} />
      </.link>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp status_line(0), do: copy("All clear")

  defp status_line(count),
    do: copy_n("%{count} thing needs you", "%{count} things need you", count)

  defp status_tone([], 0), do: "text-success"

  defp status_tone(urgent, waiting),
    do:
      if(waiting > 0 or Enum.any?(urgent, &(&1.level == :act)),
        do: "text-error",
        else: "text-warning"
      )
end
