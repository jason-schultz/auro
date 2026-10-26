defmodule OpusWeb.DashboardLive do
  @moduledoc """
  The home page: what needs the user now (`Opus.Dashboard.Alerts`, most
  urgent first, each with what to do), one tile each for live trading, the
  paper options books, the accounts and this month's index exposure, and
  what the books did last night.

  Refreshes every five minutes. Broker balances are slow, so the Accounts
  tile (and any offline-broker alert) fills in after the rest.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format

  alias Opus.Dashboard

  @refresh_ms :timer.minutes(5)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Dashboard",
        data: nil,
        alerts: [],
        accounts: :loading,
        offline: [],
        as_of: nil
      )

    {:ok, if(connected?(socket), do: refresh(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_async(:accounts, {:ok, {:ok, overview}}, socket) do
    {:noreply,
     socket
     |> assign(accounts: {:ok, overview.total_cad}, offline: overview.offline)
     |> assign_alerts()}
  end

  def handle_async(:accounts, _result, socket) do
    {:noreply, assign(socket, accounts: :unavailable)}
  end

  defp refresh(socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    socket
    |> assign(data: Dashboard.gather(), as_of: DateTime.utc_now())
    |> assign_alerts()
    |> start_async(:accounts, &Dashboard.accounts/0)
  end

  defp assign_alerts(%{assigns: %{data: data, offline: offline}} = socket),
    do: assign(socket, alerts: Dashboard.alerts(data.input, offline))

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        urgent: Enum.filter(assigns.alerts, &(&1.level in [:act, :check])),
        fyi: Enum.filter(assigns.alerts, &(&1.level == :fyi))
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <div class="flex flex-wrap items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t s="Dashboard" wsb="War room" />
            </h1>
            <span :if={@data} class={["text-[14px] font-medium", status_tone(@urgent)]}>
              <.t s={status_line(@urgent, :serious)} wsb={status_line(@urgent, :wsb)} />
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
          <.t s="Checking everything…" wsb="Checking the bags…" />
        </p>

        <%= if @data do %>
          <section aria-label="Needs you" class="flex flex-col gap-3">
            <span class="text-[15px] font-semibold">
              <.t s="Needs you" wsb="GUH alerts" />
            </span>
            <p
              :if={@urgent == []}
              class="rounded-box border border-success/40 bg-base-200 px-5 py-4 text-[14px]"
            >
              <.t s="Nothing needs you." wsb="Sir, this is a Wendy's. Nothing to do." />
            </p>
            <.alert_card :for={alert <- @urgent} alert={alert} />
          </section>

          <section aria-label="Overview" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.live_tile live={@data.live} />
            <.paper_tile books={@data.books} />
            <.accounts_tile accounts={@accounts} />
            <.exposure_tile exposure={@data.exposure} />
          </section>

          <section :if={@fyi != []} aria-label="Last night" class="flex flex-col gap-2">
            <span class="text-[15px] font-semibold">
              <.t s="Last night and today" wsb="Tendies report" />
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
    </Layouts.app>
    """
  end

  attr :alert, :map, required: true

  defp alert_card(assigns) do
    ~H"""
    <article class={[
      "flex flex-col gap-1.5 rounded-box border bg-base-200 px-5 py-4",
      if(@alert.level == :act, do: "border-error/50", else: "border-warning/50")
    ]}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class="text-[15px] font-semibold">{@alert.title}</span>
        <span class={[
          "text-[12px] font-medium",
          if(@alert.level == :act, do: "text-error", else: "text-warning")
        ]}>
          <.t
            :if={@alert.level == :act}
            s="Act now"
            wsb="GUH alert"
          />
          <.t :if={@alert.level == :check} s="Check soon" wsb="Keep an eye on it" />
        </span>
      </div>
      <p :if={@alert.detail} class="text-[13px] text-muted">{@alert.detail}</p>
      <p class="text-[13px]">
        <span class="font-medium"><.t s="What to do:" wsb="The play:" /></span>
        {@alert.what_to_do}
      </p>
      <.link
        :if={@alert.link}
        navigate={@alert.link}
        class="self-start text-[13px] font-medium text-primary hover:brightness-110"
      >
        Open →
      </.link>
    </article>
    """
  end

  attr :live, :map, required: true

  defp live_tile(assigns) do
    ~H"""
    <.tile title="Live trading" wsb="Live (fake) money" link={~p"/strategies"}>
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
    <.tile title="Paper options" wsb="Casino chips" link={~p"/options?view=paper"}>
      <ul class="m-0 flex list-none flex-col gap-1 p-0 text-[13px]">
        <li :for={book <- @books} class="flex justify-between gap-3">
          <.link navigate={book.link} class="hover:text-primary">
            <.t s={book.name} wsb={book.wsb} />
            <span :if={book.open > 0} class="text-muted">· {book.open} open</span>
          </.link>
          <span :if={book.started} class={tone(book.pnl)}>{signed_money(book.pnl)}</span>
          <span :if={!book.started} class="text-muted">not started</span>
        </li>
      </ul>
    </.tile>
    """
  end

  attr :accounts, :any, required: true

  defp accounts_tile(assigns) do
    ~H"""
    <.tile title="Accounts" wsb="The bag" link={~p"/accounts"}>
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
    <.tile title="Index exposure" wsb="YOLO meter" link={~p"/accounts"}>
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

  attr :title, :string, required: true
  attr :wsb, :string, required: true
  attr :link, :string, required: true
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <.link
      navigate={@link}
      class="flex flex-col gap-1 rounded-box border border-base-300 bg-base-200 px-5 py-4 hover:border-primary"
    >
      <span class="text-[12px] text-muted"><.t s={@title} wsb={@wsb} /></span>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp status_line([], :serious), do: "All clear"
  defp status_line([], :wsb), do: "No GUH today"
  defp status_line([_], :serious), do: "1 thing needs you"
  defp status_line([_], :wsb), do: "1 thing needs you, regard"
  defp status_line(urgent, :serious), do: "#{length(urgent)} things need you"
  defp status_line(urgent, :wsb), do: "#{length(urgent)} things need you, regard"

  defp status_tone([]), do: "text-success"

  defp status_tone(urgent),
    do: if(Enum.any?(urgent, &(&1.level == :act)), do: "text-error", else: "text-warning")

  defp signed_money(nil), do: "—"
  defp signed_money(value) when value < 0, do: "−" <> money(abs(value))
  defp signed_money(value), do: "+" <> money(value)

  defp tone(nil), do: nil
  defp tone(value) when value < 0, do: "text-error"
  defp tone(value) when value > 0, do: "text-success"
  defp tone(_value), do: nil
end
