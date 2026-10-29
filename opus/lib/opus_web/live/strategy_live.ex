defmodule OpusWeb.StrategyLive do
  @moduledoc """
  One strategy on one instrument: its switch, whether its
  recipe is locked and the way to edit it (`OpusWeb.StrategyBuilderLive`),
  the other instruments the recipe runs on, the rules engine's verdict and
  the regime behind it, a chart of every buy and sell the rules made over
  the last bars with the rule strips that say why (the engine's signal
  preview, loaded after the page; the plain candle chart with the open
  position stands in while it loads or when the engine is down), the rules
  in plain words, the indicator scalars right now, the test results (how it
  did against just holding the instrument over its whole test history, an
  on-demand "is it fragile?" check at nearby settings, and the evidence
  ladder: backtest, walk-forward, Monte Carlo, holdout, live), its trades
  and its signal log.

  Everything but the statistics and indicator scalars comes from Opus's own
  tables, so the page stands when the engine is down and says so.
  """
  use OpusWeb, :live_view

  import OpusWeb.CandleChart
  import OpusWeb.Format
  import OpusWeb.SignalChart, only: [signal_chart: 1]
  import OpusWeb.StrategyParts

  alias Opus.Auro.Client
  alias Opus.Journal.TradeStory
  alias Opus.Trading.Strategies
  alias OpusWeb.WholeHistory

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        id: id,
        s: nil,
        page_title: "Strategy",
        signals: nil,
        focus: nil,
        preview_error: nil
      )
      |> WholeHistory.init()

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("fragility_axes", params, socket),
    do: {:noreply, WholeHistory.pick_axes(socket, params)}

  def handle_event("check_fragility", _params, %{assigns: %{s: s}} = socket) do
    {x, y} = WholeHistory.chosen_axes(socket.assigns)

    {:noreply,
     socket
     |> assign(fragility: :running)
     |> start_async(:fragility, fn ->
       Strategies.fragility(
         s.recipe.definition,
         s.instrument,
         s.granularity,
         s.sizing_params,
         x,
         y
       )
     end)}
  end

  def handle_event("pick_trade", %{"trade" => trade}, socket),
    do: {:noreply, assign(socket, focus: String.to_integer(trade))}

  def handle_event("toggle", _params, socket) do
    case Strategies.toggle(socket.assigns.id) do
      {:ok, %{"enabled" => enabled}} ->
        {:noreply,
         socket
         |> put_flash(:info, if(enabled, do: "Strategy enabled.", else: "Strategy disabled."))
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not flip the switch: #{describe(reason)}")}
    end
  end

  def handle_event("reset", _params, socket) do
    case Strategies.reset_suspension(socket.assigns.id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Suspension cleared; rules recomputing.") |> load()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "No open suspension to clear.") |> load()}
    end
  end

  def handle_event("delete", _params, socket) do
    case Strategies.delete(socket.assigns.id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Strategy deleted.") |> push_navigate(to: ~p"/strategies")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete: #{describe(reason)}")}
    end
  end

  defp load(socket) do
    case Strategies.get(socket.assigns.id) do
      {:ok, s} ->
        socket
        |> assign(s: s, page_title: s.recipe.name)
        |> WholeHistory.assign_axes(s.recipe.definition)
        |> start_async(:preview, fn ->
          Strategies.preview(s.recipe.definition, s.instrument, s.granularity, s.sizing_params)
        end)
        |> start_async(:report, fn ->
          Strategies.report(s.recipe.definition, s.instrument, s.granularity, s.sizing_params)
        end)

      :error ->
        socket |> put_flash(:error, "No such strategy.") |> push_navigate(to: ~p"/strategies")
    end
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, chart}}, socket),
    do: {:noreply, assign(socket, signals: chart, preview_error: nil)}

  def handle_async(:preview, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, preview_error: describe(reason))}

  def handle_async(:preview, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, preview_error: "The signal preview didn't finish.")}

  def handle_async(name, result, socket) when name in [:report, :fragility],
    do: {:noreply, WholeHistory.put_result(socket, name, result)}

  defp describe(reason), do: Client.describe_error(reason)

  @impl true
  def render(%{s: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <p class="text-[13px] text-muted">Loading…</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, last_close: last_close(assigns.s.candles))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-8">
        <div class="flex flex-col gap-3">
          <.link
            navigate={~p"/strategies"}
            class="self-start text-[13px] text-muted hover:text-base-content"
          >
            ← <.t {copy("Strategies")} />
          </.link>
          <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
            <div class="flex flex-col gap-1">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <h1 class="text-[24px] font-semibold leading-tight tracking-tight">
                  {@s.recipe.name}
                </h1>
                <.lock_badge locked_by={@s.locked_by} />
              </div>
              <span class="text-[14px] text-muted">
                {@s.instrument} · {@s.recipe.timeframe} · {@s.sizing} ·
                <.t {copy("deployed")} /> {stamp(@s.created_at)}
              </span>
              <div class="flex flex-wrap gap-2 pt-1">
                <.link
                  navigate={~p"/strategies/recipes/#{@s.recipe.id}/edit?copy=1"}
                  class="inline-flex min-h-11 items-center rounded-field border border-base-300 px-3.5 text-[14px] font-medium hover:border-primary"
                >
                  <.t {copy("Copy as a new strategy")} />
                </.link>
                <.link
                  navigate={~p"/strategies/recipes/#{@s.recipe.id}/edit"}
                  class="inline-flex min-h-11 items-center gap-2 rounded-field bg-base-content px-3.5 text-[14px] font-semibold text-base-100 hover:brightness-110"
                >
                  <.icon
                    name={if @s.locked_by == [], do: "hero-pencil-mini", else: "hero-lock-open-mini"}
                    class="size-4"
                  />
                  <%= if @s.locked_by == [] do %>
                    <.t {copy("Edit the rules")} />
                  <% else %>
                    <.t {copy("Unlock to edit")} />
                  <% end %>
                </.link>
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-x-5 gap-y-2 text-[14px]">
              <button
                type="button"
                phx-click="toggle"
                disabled={@s.suspension != nil}
                aria-pressed={to_string(@s.enabled)}
                class={[
                  "inline-flex min-h-11 items-center gap-2 rounded-field border border-base-300 bg-base-200 px-3.5 font-medium disabled:cursor-not-allowed disabled:opacity-50",
                  if(@s.enabled, do: "text-success", else: "text-muted")
                ]}
              >
                <span
                  aria-hidden="true"
                  class={[
                    "size-2 rounded-full",
                    if(@s.enabled, do: "bg-success", else: "bg-base-300")
                  ]}
                />
                <.t :if={@s.enabled} {copy("Enabled")} />
                <.t :if={!@s.enabled} {copy("Disabled")} />
              </button>
              <button
                type="button"
                phx-click="delete"
                data-confirm={"Delete #{@s.name}? This cannot be undone."}
                disabled={@s.open_trades > 0}
                title={if @s.open_trades > 0, do: "A strategy with an open trade cannot be deleted"}
                class="text-error disabled:cursor-not-allowed disabled:text-muted"
              >
                <.t {copy("Delete")} />
              </button>
            </div>
          </div>
          <div
            :if={@s.suspension}
            class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-box border border-error/40 bg-base-200 px-4 py-3 text-sm"
          >
            <span class="font-medium text-error"><.t {copy("Suspended by the circuit breaker")} /></span>
            <span class="text-muted">{@s.suspension.trigger_detail} · {stamp(
              @s.suspension.triggered_at
            )}</span>
            <button
              type="button"
              phx-click="reset"
              class="font-medium text-primary hover:brightness-110"
            ><.t {copy("Reset")} /></button>
          </div>
        </div>

        <p
          :if={@s.engine_error}
          role="alert"
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          {describe(@s.engine_error)} Showing what Opus knows; statistics and indicator scalars need the engine.
        </p>

        <nav
          :if={length(@s.siblings) > 1}
          aria-label="Instruments this strategy runs on"
          class="-mt-4 flex flex-wrap gap-1 border-b border-base-300"
        >
          <.link
            :for={sib <- @s.siblings}
            navigate={~p"/strategies/#{sib.id}"}
            aria-current={sib.id == @s.id && "page"}
            class={[
              "inline-flex min-h-11 items-center border-b-2 px-3.5 text-[14px]",
              if(sib.id == @s.id,
                do: "border-primary font-semibold",
                else: "border-transparent text-muted hover:text-base-content"
              )
            ]}
          >
            {sib.instrument}
            <span :if={!sib.enabled} class="ml-1.5 text-[12px] text-muted">off</span>
          </.link>
        </nav>

        <section aria-label="Status" class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-4">
          <.card label={copy("Rules engine")}>
            <.verdict s={@s} />
          </.card>
          <.card label={copy("Regime")}>
            <%= if @s.rule do %>
              <span class="text-[18px] font-semibold">{String.capitalize(
                @s.rule.composite || "unknown"
              )}</span>
              <span class="text-[13px] text-muted">
                {Enum.map_join(
                  @s.rule.frames,
                  " · ",
                  &"#{&1.frame} ADX #{num(&1.adx, 1)} #{&1.regime}"
                )}
              </span>
            <% else %>
              <span class="text-[18px] font-semibold text-muted">—</span>
            <% end %>
          </.card>
          <.card label={copy("Open position")}>
            <%= if @s.open_trade do %>
              <span class="text-[18px] font-semibold">
                {@s.open_trade.direction} {@s.open_trade.units} units
                <span class={tone(unrealized(@s.open_trade, @last_close))}>
                  {signed_pct(unrealized(@s.open_trade, @last_close))}
                </span>
              </span>
              <span class="text-[13px] text-muted">
                entry {price(@s.open_trade.entry_price)} · last {price(@last_close)} · {held(
                  @s.open_trade.entry_time,
                  nil
                )}
              </span>
            <% else %>
              <span class="text-[18px] font-semibold text-muted"><.t {copy("Flat")} /></span>
              <span class="text-[13px] text-muted">{@s.open_trades} open · last close {price(
                @last_close
              )}</span>
            <% end %>
          </.card>
          <.card label={copy("Last signal")}>
            <%= if @s.last_signal do %>
              <span class="text-[18px] font-semibold">{action(@s.last_signal.action)}</span>
              <span class="truncate text-[13px] text-muted" title={@s.last_signal.reason}>
                {@s.last_signal.reason} · {stamp(@s.last_signal.at)}
              </span>
            <% else %>
              <span class="text-[18px] font-semibold text-muted"><.t {copy("None yet")} /></span>
            <% end %>
          </.card>
        </section>

        <section
          aria-label="Chart"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <%= if @signals do %>
            <span class="text-[15px] font-semibold">
              {@s.instrument} ·
              <.t {copy("every buy and sell the rules made over the last 120 bars")} />
            </span>
            <.signal_chart
              chart={@signals}
              definition={@s.recipe.definition}
              granularity={@s.granularity}
              focus={@focus}
              label={"#{@s.granularity} candles for #{@s.instrument} with buy and sell signals"}
            />
          <% else %>
            <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
              <span class="text-[15px] font-semibold">{@s.instrument} · {@s.granularity} · last {@s.chart_bars} completed bars</span>
              <span class="text-[13px] text-muted">
                {@preview_error ||
                  "Loading the buy and sell signals…"}
              </span>
            </div>
            <.candle_chart
              candles={@s.candles}
              bars={@s.chart_bars}
              overlay_period={@s.overlay_period}
              lines={chart_lines(@s.open_trade, @last_close)}
              label={"#{@s.granularity} candles for #{@s.instrument}"}
            />
          <% end %>
        </section>

        <section class="grid grid-cols-[repeat(auto-fit,minmax(300px,1fr))] gap-4">
          <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <span class="text-[15px] font-semibold"><.t {copy("How it trades")} /></span>
            <dl class="grid grid-cols-1 gap-x-4 gap-y-2.5 text-[14px] sm:grid-cols-[max-content_minmax(0,1fr)]">
              <%= for {label, text} <- @s.recipe.rules do %>
                <dt class="text-muted">{label}</dt>
                <dd class="m-0 break-words">{text}</dd>
              <% end %>
              <dt class="text-muted"><.t {copy("Size here")} /></dt>
              <dd class="m-0">{@s.sizing}</dd>
            </dl>
          </div>
          <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <span class="text-[15px] font-semibold"><.t {copy("Right now")} /></span>
              <span :if={@s.indicators} class="text-[13px] text-muted">
                {@s.granularity} buffer, {@s.indicators["buffer_size"]} bars
              </span>
            </div>
            <%= if @s.indicators do %>
              <dl class="grid grid-cols-2 gap-x-4 gap-y-3.5">
                <.stat label={copy("ADX 14")} value={num(@s.indicators["indicators"]["adx"], 1)} />
                <.stat
                  label={copy("ATR 14")}
                  value={pct_points(@s.indicators["indicators"]["atr_pct"])}
                />
                <.stat
                  label={copy("Distance to MA 20")}
                  value={pct_points(@s.indicators["indicators"]["ma_deviation_pct"])}
                />
                <.stat
                  label={copy("Rate of change")}
                  value={pct_points(@s.indicators["indicators"]["roc_pct"])}
                />
                <.stat
                  label={copy("Bollinger width")}
                  value={
                    pct_points(get_in(@s.indicators, ["indicators", "bollinger", "bandwidth_pct"]))
                  }
                />
                <.stat
                  label={copy("Position in bands")}
                  value={num(get_in(@s.indicators, ["indicators", "bollinger", "position"]))}
                />
              </dl>
              <p class="text-[13px] text-muted">
                The scalars Opus polls for the regime detector. They describe the market, not a distance to the next entry.
              </p>
            <% else %>
              <p class="text-[13px] text-muted">
                Indicator scalars come from the engine's candle buffer and are unavailable while it is down.
              </p>
            <% end %>
          </div>
        </section>

        <section
          id="tests"
          aria-label="Test results"
          class="flex scroll-mt-24 flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <span class="text-[15px] font-semibold">
            <.t {copy("Test results on %{instrument}", instrument: @s.instrument)} />
          </span>
          <WholeHistory.panel
            report={@report}
            fragility={@fragility}
            axes={@axes}
            fx={@fx}
            fy={@fy}
            instrument={@s.instrument}
            granularity={@s.granularity}
          />

          <.evidence results={@s.results} />
          <div :if={@s.runs != []} class="flex flex-col gap-2 border-t border-neutral pt-4">
            <span class="text-[14px] font-medium">
              <.t {copy("Also tested on (not running there)")} />
            </span>
            <.runs_list runs={@s.runs} />
          </div>
        </section>

        <section
          aria-label="Trades"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <span class="text-[15px] font-semibold"><.t {pcopy("strategy page", "Trades")} /></span>
            <.link
              navigate={~p"/journal"}
              class="text-[13px] font-medium text-primary hover:brightness-110"
            ><.t {copy("Open the journal")} /></.link>
          </div>
          <p :if={@s.trades == []} class="text-[14px] text-muted">
            <.t {copy("None yet. The first trade this strategy opens will appear here with why it closed.")} />
          </p>
          <div :if={@s.trades != []} class="overflow-x-auto">
            <table class="w-full min-w-[720px] border-collapse text-sm">
              <thead>
                <tr class="text-left text-xs text-muted">
                  <th class="border-b border-base-300 py-2 font-medium">Opened</th>
                  <th class="border-b border-base-300 py-2 font-medium">Side</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Units</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Entry</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Exit</th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">
                    <.t {copy("Result")} />
                  </th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Held</th>
                  <th class="border-b border-base-300 py-2 pl-6 font-medium">
                    <.t {copy("Why it closed")} />
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @s.trades} class="border-b border-neutral last:border-b-0">
                  <td class="py-2.5">
                    <.link navigate={~p"/journal?trade=#{t.id}"} class="text-primary hover:underline">
                      {stamp(t.entry_time)}
                    </.link>
                  </td>
                  <td class="py-2.5">{t.direction}</td>
                  <td class="py-2.5 text-right">{t.units}</td>
                  <td class="py-2.5 text-right">{price(t.entry_price)}</td>
                  <td class={["py-2.5 text-right", is_nil(t.exit_price) && "text-muted"]}>
                    {if t.exit_price, do: price(t.exit_price), else: "open"}
                  </td>
                  <td class={["py-2.5 text-right", tone(t.pnl_percent)]}>
                    {signed_pct(t.pnl_percent)}
                  </td>
                  <td class="py-2.5 text-right">{held(t.entry_time, t.exit_time)}</td>
                  <td class="max-w-[320px] truncate py-2.5 pl-6 text-muted" title={t.exit_reason}>
                    {TradeStory.exit_label(t)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          aria-label="Recent signals"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <span class="text-[15px] font-semibold"><.t {copy("Recent signals")} /></span>
            <span class="text-[13px] text-muted">
              <.t {copy("every evaluation that did something, newest first")} />
            </span>
          </div>
          <p :if={@s.signals == []} class="text-[14px] text-muted">
            <.t {copy("None yet.")} />
          </p>
          <ol :if={@s.signals != []} class="m-0 flex list-none flex-col p-0">
            <li
              :for={e <- @s.signals}
              class="grid grid-cols-[110px_minmax(0,1fr)] gap-x-4 gap-y-0.5 border-b border-neutral py-2.5 text-[14px] last:border-b-0 sm:grid-cols-[110px_150px_minmax(0,1fr)]"
            >
              <span class="text-muted">{stamp(e.at)}</span>
              <span class={["font-medium", e.action == "entry_rejected" && "text-warning"]}>{action(
                e.action
              )}</span>
              <span class="col-span-2 break-words sm:col-span-1">{e.reason}
              <span class="text-muted">at {price(e.price)}</span></span>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :map, required: true, doc: "copy/1"
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 px-[18px] py-4">
      <span class="text-xs text-muted"><.t {@label} /></span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :map, required: true, doc: "copy/1"
  attr :value, :string, required: true
  attr :large, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <dt class="text-xs text-muted"><.t {@label} /></dt>
      <dd class={["m-0 font-semibold", if(@large, do: "text-[22px]", else: "text-[18px]")]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :s, :map, required: true

  defp verdict(%{s: %{enabled: false}} = assigns) do
    ~H"""
    <span class="text-[18px] font-semibold text-muted"><.t {copy("Off")} /></span>
    <span class="text-[13px] text-muted"><.t {copy("disabled, the rules engine skips it")} /></span>
    """
  end

  defp verdict(%{s: %{rule: nil}} = assigns) do
    ~H"""
    <span class="text-[18px] font-semibold text-muted"><.t {copy("No decision yet")} /></span>
    """
  end

  defp verdict(assigns) do
    ~H"""
    <span class={[
      "text-[18px] font-semibold",
      if(@s.rule.enabled, do: "text-success", else: "text-warning")
    ]}>
      <.t :if={@s.rule.enabled} {copy("Trading")} />
      <.t :if={!@s.rule.enabled} {copy("Held")} />
    </span>
    <span class="text-[13px] text-muted">
      {@s.rule.reason} · <.t {copy("decided")} /> {stamp(@s.rule.computed_at)}
    </span>
    <span :if={@s.circuit_breaker_exempt} class="text-[13px] text-warning">
      <.t {copy("Circuit breaker off: kept trading through losing streaks by choice.")} />
    </span>
    """
  end

  defp last_close([]), do: nil
  defp last_close(candles), do: List.last(candles).close

  defp unrealized(_trade, nil), do: nil

  defp unrealized(%{entry_price: entry, direction: direction}, last)
       when is_number(entry) and entry > 0 do
    sign = if String.downcase(direction || "") == "short", do: -1, else: 1
    sign * (last - entry) / entry
  end

  defp unrealized(_trade, _last), do: nil

  defp chart_lines(nil, last), do: [%{price: last, label: "Last", kind: :now}]

  defp chart_lines(trade, last) do
    [
      %{price: trade.entry_price, label: "Entry", kind: :entry},
      %{price: trade.stop_loss_price, label: "Stop", kind: :stop},
      %{price: trade.take_profit_price, label: "Target", kind: :target},
      %{price: last, label: "Last", kind: :now}
    ]
  end

  defp pct_points(nil), do: "—"
  defp pct_points(v), do: "#{num(v)}%"

  defp action(action), do: action |> String.replace("_", " ") |> String.capitalize()
end
