defmodule OpusWeb.StrategyLive do
  @moduledoc """
  One live strategy: its switch and curator state, the rules engine's
  verdict and the regime behind it, the open position on a candle chart with
  its entry and stop, how the strategy decides (its components and rules),
  the indicator scalars right now, validation against the live record, its
  trades and its signal log.

  Everything but the statistics and indicator scalars comes from Opus's own
  tables, so the page stands when the engine is down and says so.
  """
  use OpusWeb, :live_view

  import OpusWeb.CandleChart
  import OpusWeb.Format

  alias Opus.Auro.Client
  alias Opus.Trading.Strategies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket = assign(socket, id: id, s: nil, page_title: "Strategy")
    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

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

  def handle_event("curator", _params, socket) do
    case Strategies.hand_back_to_curator(socket.assigns.id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Handed back to the curator.") |> load()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not change curator mode: #{describe(reason)}")}
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
        assign(socket, s: s, page_title: s.name)

      :error ->
        socket |> put_flash(:error, "No such strategy.") |> push_navigate(to: ~p"/strategies")
    end
  end

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
            ← <.t s="Strategies" wsb="Plays" />
          </.link>
          <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
            <div class="flex flex-col gap-1">
              <h1 class="text-[24px] font-semibold leading-tight tracking-tight">{@s.name}</h1>
              <span class="text-[14px] text-muted">
                {@s.instrument} · {@s.granularity} · {type_label(@s.strategy_type)} ·
                <.t
                  s="deployed"
                  wsb="sent"
                /> {stamp(@s.created_at)}
              </span>
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
                <.t :if={@s.enabled} s="Enabled" wsb="Sending it" />
                <.t :if={!@s.enabled} s="Disabled" wsb="Benched" />
              </button>
              <span class="text-muted">
                {curator(@s.curator_mode)}
                <button
                  :if={@s.curator_mode != "auto"}
                  type="button"
                  phx-click="curator"
                  class="ml-1 font-medium text-primary hover:brightness-110"
                >
                  <.t s="hand back to curator" wsb="let the curator cook" />
                </button>
              </span>
              <button
                type="button"
                phx-click="delete"
                data-confirm={"Delete #{@s.name}? This cannot be undone."}
                disabled={@s.open_trades > 0}
                title={if @s.open_trades > 0, do: "A strategy with an open trade cannot be deleted"}
                class="text-error disabled:cursor-not-allowed disabled:text-muted"
              >
                <.t s="Delete" wsb="Yeet" />
              </button>
            </div>
          </div>
          <div
            :if={@s.suspension}
            class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-box border border-error/40 bg-base-200 px-4 py-3 text-sm"
          >
            <span class="font-medium text-error"><.t
              s="Suspended by the circuit breaker"
              wsb="Benched by the circuit breaker"
            /></span>
            <span class="text-muted">{@s.suspension.trigger_detail} · {stamp(
              @s.suspension.triggered_at
            )}</span>
            <button
              type="button"
              phx-click="reset"
              class="font-medium text-primary hover:brightness-110"
            ><.t s="Reset" wsb="Un-bench" /></button>
          </div>
        </div>

        <p
          :if={@s.engine_error}
          role="alert"
          class="rounded-box border border-warning/40 bg-base-200 px-4 py-3 text-sm"
        >
          {describe(@s.engine_error)} Showing what Opus knows; statistics and indicator scalars need the engine.
        </p>

        <section aria-label="Status" class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-4">
          <.card label="Rules engine" wsb_label="The overlords">
            <.verdict s={@s} />
          </.card>
          <.card label="Regime" wsb_label="Vibe check">
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
          <.card label="Open position" wsb_label="The bag">
            <%= if @s.open_trade do %>
              <span class="text-[18px] font-semibold">
                {@s.open_trade.direction} {@s.open_trade.units} units
                <span class={gain_class(unrealized(@s.open_trade, @last_close))}>
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
              <span class="text-[18px] font-semibold text-muted"><.t s="Flat" wsb="No bags" /></span>
              <span class="text-[13px] text-muted">{@s.open_trades} open · last close {price(
                @last_close
              )}</span>
            <% end %>
          </.card>
          <.card label="Last signal" wsb_label="Last move">
            <%= if @s.last_signal do %>
              <span class="text-[18px] font-semibold">{action(@s.last_signal.action)}</span>
              <span class="truncate text-[13px] text-muted" title={@s.last_signal.reason}>
                {@s.last_signal.reason} · {stamp(@s.last_signal.at)}
              </span>
            <% else %>
              <span class="text-[18px] font-semibold text-muted"><.t s="None yet" wsb="Crickets" /></span>
            <% end %>
          </.card>
        </section>

        <section
          aria-label="Chart"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <span class="text-[15px] font-semibold">{@s.instrument} · {@s.granularity} · last {@s.chart_bars} completed bars</span>
            <div class="flex flex-wrap gap-x-4 gap-y-1 text-[13px] text-muted">
              <span :if={@s.open_trade}><span
                aria-hidden="true"
                class="mr-1.5 inline-block w-4 border-t border-dashed border-neutral-content align-middle"
              ></span>Entry</span>
              <span :if={@s.open_trade && @s.open_trade.stop_loss_price}><span
                aria-hidden="true"
                class="mr-1.5 inline-block w-4 border-t-2 border-error align-middle"
              ></span><.t s="Stop" wsb="Stop, the paper-hands line" /></span>
              <span :if={@s.open_trade && @s.open_trade.take_profit_price}><span
                aria-hidden="true"
                class="mr-1.5 inline-block w-4 border-t-2 border-success align-middle"
              ></span><.t s="Target" wsb="Target, the tendies line" /></span>
              <span :if={@s.open_trade && is_nil(@s.open_trade.take_profit_price)}><.t
                s="No take profit; the exit rule closes it"
                wsb="No target; we ride until the rule says GUH"
              /></span>
              <span :if={@s.overlay_period}><span
                aria-hidden="true"
                class="mr-1.5 inline-block w-4 border-t-2 border-accent align-middle"
              ></span>SMA {@s.overlay_period}</span>
              <span><span
                aria-hidden="true"
                class="mr-1.5 inline-block w-4 border-t-2 border-primary align-middle"
              ></span>Last close</span>
            </div>
          </div>
          <.candle_chart
            candles={@s.candles}
            bars={@s.chart_bars}
            overlay_period={@s.overlay_period}
            lines={chart_lines(@s.open_trade, @last_close)}
            label={"#{@s.granularity} candles for #{@s.instrument}"}
          />
        </section>

        <section class="grid grid-cols-[repeat(auto-fit,minmax(300px,1fr))] gap-4">
          <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <span class="text-[15px] font-semibold"><.t s="How it decides" wsb="The DD" /></span>
            <div
              :for={component <- @s.logic.components}
              class="flex flex-col gap-0.5 rounded-field bg-base-100 px-3.5 py-3"
            >
              <span class="font-medium">
                <code class="mr-1 text-[13px] text-accent">{component.key}</code>{component.type}
              </span>
              <span class="text-[13px] text-muted">
                {Enum.map_join(component.params, " · ", fn {k, v} -> "#{k} #{v}" end)}
              </span>
            </div>
            <dl
              :if={@s.logic.rules != []}
              class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2.5 text-[14px]"
            >
              <%= for {label, text} <- @s.logic.rules do %>
                <dt class="text-muted">{label}</dt>
                <dd class="m-0 break-words"><code class="text-[13px]">{text}</code></dd>
              <% end %>
            </dl>
            <dl
              :if={@s.logic.settings != []}
              class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2.5 text-[14px]"
            >
              <%= for {key, value} <- @s.logic.settings do %>
                <dt class="text-muted">{key}</dt>
                <dd class="m-0">{value}</dd>
              <% end %>
            </dl>
          </div>
          <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <span class="text-[15px] font-semibold"><.t s="Right now" wsb="Vibe readout" /></span>
              <span :if={@s.indicators} class="text-[13px] text-muted">
                {@s.granularity} buffer, {@s.indicators["buffer_size"]} bars
              </span>
            </div>
            <%= if @s.indicators do %>
              <dl class="grid grid-cols-2 gap-x-4 gap-y-3.5">
                <.stat label="ADX 14" value={num(@s.indicators["indicators"]["adx"], 1)} />
                <.stat label="ATR 14" value={pct_points(@s.indicators["indicators"]["atr_pct"])} />
                <.stat
                  label="Distance to MA 20"
                  value={pct_points(@s.indicators["indicators"]["ma_deviation_pct"])}
                />
                <.stat
                  label="Rate of change"
                  value={pct_points(@s.indicators["indicators"]["roc_pct"])}
                />
                <.stat
                  label="Bollinger width"
                  value={
                    pct_points(get_in(@s.indicators, ["indicators", "bollinger", "bandwidth_pct"]))
                  }
                />
                <.stat
                  label="Position in bands"
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
          aria-label="Validation"
          class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <span class="text-[15px] font-semibold"><.t
              s="Validation against the live record"
              wsb="Backtest vs reality"
            /></span>
            <span :if={@s.stats} class="text-[13px] text-muted">source {@s.stats.source || "—"}</span>
          </div>
          <%= if @s.stats do %>
            <dl class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-x-4 gap-y-3.5">
              <.stat
                label="Backtest Sharpe"
                value={num(get_in(@s.stats, [:backtest, "sharpe_ratio"]))}
                large
              />
              <.stat
                label="Out of sample Sharpe"
                value={num(get_in(@s.stats, [:oos, "oos_sharpe"]))}
                large
              />
              <.stat label="k-fold" value={kfold(@s.stats.kfold)} large />
              <.stat
                label="Live trades"
                wsb_label="Live plays"
                value={to_string(get_in(@s.stats, [:live, "num_trades"]) || 0)}
                large
              />
              <.stat
                label="Live win rate"
                wsb_label="Hit rate"
                value={pct(get_in(@s.stats, [:live, "win_rate"]))}
                large
              />
              <.stat
                label="Live return"
                wsb_label="Tendies"
                value={signed_pct(get_in(@s.stats, [:live, "total_return"]))}
                large
              />
            </dl>
          <% else %>
            <p class="text-[13px] text-muted">
              Backtest, out-of-sample and live statistics are aggregated by the engine and unavailable while it is down.
            </p>
          <% end %>
        </section>

        <section
          aria-label="Trades"
          class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <span class="text-[15px] font-semibold"><.t s="Trades" wsb="Positions (or ban)" /></span>
            <.link
              navigate={~p"/journal"}
              class="text-[13px] font-medium text-primary hover:brightness-110"
            ><.t s="Open the journal" wsb="Open the loss porn" /></.link>
          </div>
          <p :if={@s.trades == []} class="text-[14px] text-muted">
            <.t
              s="None yet. The first trade this strategy opens will appear here with why it closed."
              wsb="No positions. Ban pending. The first play shows up here with how it died."
            />
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
                    <.t s="Result" wsb="Tendies" />
                  </th>
                  <th class="border-b border-base-300 py-2 text-right font-medium">Held</th>
                  <th class="border-b border-base-300 py-2 pl-6 font-medium">
                    <.t s="Why it closed" wsb="How it died" />
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @s.trades} class="border-b border-neutral last:border-b-0">
                  <td class="py-2.5">{stamp(t.entry_time)}</td>
                  <td class="py-2.5">{t.direction}</td>
                  <td class="py-2.5 text-right">{t.units}</td>
                  <td class="py-2.5 text-right">{price(t.entry_price)}</td>
                  <td class={["py-2.5 text-right", is_nil(t.exit_price) && "text-muted"]}>
                    {if t.exit_price, do: price(t.exit_price), else: "open"}
                  </td>
                  <td class={["py-2.5 text-right", gain_class(t.pnl_percent)]}>
                    {signed_pct(t.pnl_percent)}
                  </td>
                  <td class="py-2.5 text-right">{held(t.entry_time, t.exit_time)}</td>
                  <td class="max-w-[320px] truncate py-2.5 pl-6 text-muted" title={t.exit_reason}>
                    {exit_reason(t.exit_reason)}
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
            <span class="text-[15px] font-semibold"><.t s="Recent signals" wsb="Recent moves" /></span>
            <span class="text-[13px] text-muted">
              <.t
                s="every evaluation that did something, newest first"
                wsb="every time the bot twitched, newest first"
              />
            </span>
          </div>
          <p :if={@s.signals == []} class="text-[14px] text-muted">
            <.t s="None yet." wsb="Crickets." />
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

  attr :label, :string, required: true
  attr :wsb_label, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 px-[18px] py-4">
      <span class="text-xs text-muted"><.t s={@label} wsb={@wsb_label || @label} /></span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :wsb_label, :string, default: nil
  attr :value, :string, required: true
  attr :large, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <dt class="text-xs text-muted"><.t s={@label} wsb={@wsb_label || @label} /></dt>
      <dd class={["m-0 font-semibold", if(@large, do: "text-[22px]", else: "text-[18px]")]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :s, :map, required: true

  defp verdict(%{s: %{enabled: false}} = assigns) do
    ~H"""
    <span class="text-[18px] font-semibold text-muted"><.t s="Off" wsb="Benched" /></span>
    <span class="text-[13px] text-muted"><.t
      s="disabled, the rules engine skips it"
      wsb="benched, the overlords skip it"
    /></span>
    """
  end

  defp verdict(%{s: %{rule: nil}} = assigns) do
    ~H"""
    <span class="text-[18px] font-semibold text-muted"><.t s="No decision yet" wsb="Jury's out" /></span>
    """
  end

  defp verdict(assigns) do
    ~H"""
    <span class={[
      "text-[18px] font-semibold",
      if(@s.rule.enabled, do: "text-success", else: "text-warning")
    ]}>
      <.t :if={@s.rule.enabled} s="Trading" wsb="Sending it" />
      <.t :if={!@s.rule.enabled} s="Held" wsb="Hands tied" />
    </span>
    <span class="text-[13px] text-muted">
      {@s.rule.reason} · <.t s="decided" wsb="ruled" /> {stamp(@s.rule.computed_at)}
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

  defp gain_class(nil), do: "text-muted"
  defp gain_class(v) when v < 0, do: "text-error"
  defp gain_class(_), do: "text-success"

  defp pct_points(nil), do: "—"
  defp pct_points(v), do: "#{num(v)}%"

  defp kfold(%{"pass_count" => passed, "fold_count" => folds}), do: "#{passed}/#{folds}"
  defp kfold(_), do: "—"

  defp action(action), do: action |> String.replace("_", " ") |> String.capitalize()

  defp exit_reason(nil), do: "—"

  defp exit_reason("CompositeExit" <> _ = reason),
    do: "Composite exit: " <> String.slice(reason, 14..-1//1)

  defp exit_reason(reason), do: reason

  defp type_label(type), do: String.replace(type, "_", " ")

  defp curator("auto"), do: "curator: auto"
  defp curator("pinned_on"), do: "pinned on ·"
  defp curator("pinned_off"), do: "pinned off ·"
  defp curator(other), do: other
end
