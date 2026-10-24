defmodule OpusWeb.JournalLive do
  @moduledoc """
  Journal: the weekly forward-test review in one place. Thirty-day KPIs,
  the per-strategy leaderboard, execution quality against the backtest's
  assumed fills, holdout verdicts, open circuit-breaker suspensions and the
  frozen weekly digests.

  Everything is read from the database on mount; nothing here is pushed by
  price events.
  """
  use OpusWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import OpusWeb.Format

  alias Opus.Journal
  alias Opus.Journal.Digest
  alias Opus.Repo

  @kpi_days 30
  @execution_days 90

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Journal", kpi_days: @kpi_days, execution_days: @execution_days)
     |> load()}
  end

  defp load(socket) do
    kpi_window = Journal.window(@kpi_days)

    assign(socket,
      kpis: Journal.kpis(kpi_window),
      strategies: Journal.strategy_performance(kpi_window),
      execution: Journal.execution_quality(Journal.window(@execution_days)),
      holdouts: Journal.holdout_verdicts(),
      suspensions: Journal.open_suspensions(),
      digests: Repo.all(from(d in Digest, order_by: [desc: d.week_start], limit: 12)),
      as_of: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-12">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h1 class="text-[22px] font-semibold tracking-tight"><.t s="Journal" wsb="Loss porn" /></h1>
          <span class="text-[13px] text-muted">
            <.t s="Closed trades" wsb="Positions or ban" />, last {@kpi_days} days · {clock(@as_of)}
          </span>
        </header>

        <.kpis kpis={@kpis} />

        <.section
          title="Strategies"
          wsb_title="The plays"
          hint="Closed trades in the window; open count is current."
          wsb_hint="Closed plays in the window; the open count is live."
        >
          <.review_table
            :if={@strategies != []}
            cols={[
              {"Strategy", :left, "Play"},
              {"Trades", :right, "Plays"},
              {"Win rate", :right, "Hit rate"},
              {"P&L", :right, "Tendies"},
              {"Avg / trade", :right, "Per play"},
              {"Open", :right, "Open"}
            ]}
          >
            <tr :for={s <- @strategies}>
              <td class="py-2.5">
                <.strategy_label row={s} /> <.enabled_dot enabled={s.enabled} />
              </td>
              <td class="py-2.5 text-right">{s.trades}</td>
              <td class="py-2.5 text-right">{pct(s.win_rate_pct / 100)}</td>
              <td class={["py-2.5 text-right font-medium", pnl_class(s.pnl_cad)]}>
                {money(s.pnl_cad)}
              </td>
              <td class={["py-2.5 text-right", pnl_class(s.avg_pnl_pct)]}>
                {pct(s.avg_pnl_pct / 100)}
              </td>
              <td class="py-2.5 text-right">{s.open_trades}</td>
            </tr>
          </.review_table>
          <.empty :if={@strategies == []}>
            <.t s="No live strategies." wsb="No plays. Positions or ban." />
          </.empty>
        </.section>

        <.section
          title="Execution quality"
          wsb_title="Slippage, the hidden vol tax"
          hint={"Fills vs the backtest's assumed fills, last #{@execution_days} days. Positive = worse than backtest."}
          wsb_hint={"Fills vs what the backtest assumed, last #{@execution_days} days. Positive = you got clipped."}
        >
          <.review_table
            :if={@execution != []}
            cols={[
              {"Strategy", :left, "Play"},
              {"Trades", :right, "Plays"},
              {"Entry slip (bp)", :right, "Entry clip (bp)"},
              {"Exit slip (bp)", :right, "Exit clip (bp)"},
              {"Spread (bp)", :right, "Spread (bp)"},
              {"Round trip excess (bp)", :right, "Total clip (bp)"}
            ]}
          >
            <tr :for={e <- @execution}>
              <td class="py-2.5"><.strategy_label row={e} /></td>
              <td class="py-2.5 text-right">{e.trades}</td>
              <td class="py-2.5 text-right">{bp(e.mean_entry_slippage_bp, e.entries_measured)}</td>
              <td class="py-2.5 text-right">{bp(e.mean_exit_slippage_bp, e.exits_measured)}</td>
              <td class="py-2.5 text-right">{bp(e.mean_spread_bp, e.entries_measured)}</td>
              <td class={["py-2.5 text-right font-medium", excess_class(e.mean_round_trip_excess_bp)]}>
                {bp(e.mean_round_trip_excess_bp, min(e.entries_measured, e.exits_measured))}
              </td>
            </tr>
          </.review_table>
          <.empty :if={@execution == []}>
            <.t
              s="No measured fills yet. Rows appear as strategies trade."
              wsb="No fills measured yet. Rows appear once the plays play."
            />
          </.empty>
        </.section>

        <.section
          title="Holdout verdicts"
          wsb_title="The DD got graded"
          hint="The pipeline's one look at bars after the holdout start."
          wsb_hint="The pipeline's one look at bars it had never seen."
        >
          <.review_table
            :if={@holdouts != []}
            cols={[
              {"Config", :left, "Play"},
              {"Verdict", :left, "Verdict"},
              {"Sharpe", :right, "Sharpe"},
              {"Trades", :right, "Plays"},
              {"When", :right, "When"}
            ]}
          >
            <tr :for={h <- @holdouts}>
              <td class="py-2.5"><.strategy_label row={h} /></td>
              <td class={["py-2.5", verdict_class(h.status)]}>
                {h.status}
                <span :if={h.failure_reason} class="text-muted"> · {h.failure_reason}</span>
              </td>
              <td class="py-2.5 text-right">{stat(h.stats, "sharpe")}</td>
              <td class="py-2.5 text-right">{stat(h.stats, "num_trades")}</td>
              <td class="py-2.5 text-right text-muted">{date(h.evaluated_at)}</td>
            </tr>
          </.review_table>
          <.empty :if={@holdouts == []}>
            <.t s="No holdout runs yet." wsb="Nothing graded yet." />
          </.empty>
        </.section>

        <.section
          title="Suspended"
          wsb_title="Timeouts"
          hint="Circuit-breaker suspensions awaiting a manual reset."
          wsb_hint="The circuit breaker benched these. A human has to un-bench them."
        >
          <.review_table
            :if={@suspensions != []}
            cols={[{"Strategy", :left, "Play"}, {"Trigger", :left, "Why"}, {"Since", :right, "Since"}]}
          >
            <tr :for={s <- @suspensions}>
              <td class="py-2.5"><.strategy_label row={s} /></td>
              <td class="py-2.5">
                {s.trigger_kind} <span class="text-muted">· {s.trigger_detail}</span>
              </td>
              <td class="py-2.5 text-right text-muted">{date(s.triggered_at)}</td>
            </tr>
          </.review_table>
          <.empty :if={@suspensions == []}>
            <.t s="Nothing suspended." wsb="Nobody in timeout. Apes together strong 🦍" />
          </.empty>
        </.section>

        <.section
          title="Weekly digests"
          wsb_title="Weekly loss porn"
          hint="Frozen every Monday 08:00 ET for the week before."
          wsb_hint="Frozen every Monday 08:00 ET for the week before. Screenshots welcome."
        >
          <.review_table
            :if={@digests != []}
            cols={[
              {"Week of", :left, "Week of"},
              {"Trades", :right, "Plays"},
              {"Win rate", :right, "Hit rate"},
              {"P&L", :right, "Tendies"},
              {"Profit factor", :right, "Profit factor"}
            ]}
          >
            <tr :for={d <- @digests}>
              <td class="py-2.5">{d.week_start}</td>
              <td class="py-2.5 text-right">{d.payload["kpis"]["trade_count"]}</td>
              <td class="py-2.5 text-right">{pct((d.payload["kpis"]["win_rate_pct"] || 0) / 100)}</td>
              <td class={[
                "py-2.5 text-right font-medium",
                pnl_class(d.payload["kpis"]["total_pnl_cad"])
              ]}>
                {money(d.payload["kpis"]["total_pnl_cad"])}
              </td>
              <td class="py-2.5 text-right">{ratio(d.payload["kpis"]["profit_factor"])}</td>
            </tr>
          </.review_table>
          <.empty :if={@digests == []}>
            <.t s="First digest lands next Monday." wsb="First one drops Monday. Positions or ban." />
          </.empty>
        </.section>
      </div>
    </Layouts.app>
    """
  end

  attr :kpis, :map, required: true

  defp kpis(assigns) do
    ~H"""
    <section class="grid grid-cols-2 gap-x-8 gap-y-6 sm:grid-cols-3 lg:grid-cols-6">
      <.kpi label="Trades" wsb_label="Plays" value={@kpis.trade_count} />
      <.kpi label="Win rate" wsb_label="Hit rate" value={pct(@kpis.win_rate_pct / 100)} />
      <.kpi
        label="P&L"
        wsb_label="Tendies, net"
        value={money(@kpis.total_pnl_cad)}
        class={pnl_class(@kpis.total_pnl_cad)}
      />
      <.kpi label="Profit factor" wsb_label="Profit factor" value={ratio(@kpis.profit_factor)} />
      <.kpi
        label="Expectancy"
        wsb_label="Tendies per play"
        value={money(@kpis.expectancy_cad)}
        class={pnl_class(@kpis.expectancy_cad)}
      />
      <.kpi
        label="MFE / MAE"
        wsb_label="Peak / pain"
        value={"#{pct(@kpis.avg_mfe_pct / 100)} / #{pct(@kpis.avg_mae_pct / 100)}"}
      />
    </section>
    """
  end

  attr :label, :string, required: true
  attr :wsb_label, :string, default: nil
  attr :value, :any, required: true
  attr :class, :any, default: nil

  defp kpi(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-[13px] text-muted"><.t s={@label} wsb={@wsb_label || @label} /></span>
      <span class={["text-2xl font-semibold tracking-tight", @class]}>{@value}</span>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :wsb_title, :string, default: nil
  attr :hint, :string, default: nil
  attr :wsb_hint, :string, default: nil
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section class="flex flex-col gap-3">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <span class="text-[15px] font-semibold"><.t s={@title} wsb={@wsb_title || @title} /></span>
        <span :if={@hint} class="text-[13px] text-muted"><.t s={@hint} wsb={@wsb_hint || @hint} /></span>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :cols, :list, required: true
  slot :inner_block, required: true

  defp review_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5">
      <table class="w-full min-w-[640px] border-collapse text-sm">
        <thead>
          <tr class="text-xs text-muted">
            <th
              :for={{label, align, meme} <- @cols}
              class={[
                "border-b border-base-300 py-2.5 font-medium",
                align == :right && "text-right",
                align == :left && "text-left"
              ]}
            >
              <.t s={label} wsb={meme} />
            </th>
          </tr>
        </thead>
        <tbody>{render_slot(@inner_block)}</tbody>
      </table>
    </div>
    """
  end

  slot :inner_block, required: true

  defp empty(assigns) do
    ~H"""
    <p class="text-[13px] text-muted">{render_slot(@inner_block)}</p>
    """
  end

  attr :row, :map, required: true

  defp strategy_label(assigns) do
    ~H"""
    <span class="font-medium">{@row[:instrument] || "?"}</span>
    <span class="text-muted">{@row[:strategy_type]} {@row[:granularity]}</span>
    """
  end

  attr :enabled, :boolean, default: nil

  defp enabled_dot(assigns) do
    ~H"""
    <span
      :if={@enabled}
      aria-label="enabled"
      class="ml-1 inline-block size-[7px] rounded-full bg-primary align-middle"
    />
    """
  end

  defp pnl_class(nil), do: nil
  defp pnl_class(v) when v < 0, do: "text-error"
  defp pnl_class(v) when v > 0, do: "text-success"
  defp pnl_class(_), do: nil

  defp excess_class(nil), do: "text-muted"
  defp excess_class(v) when v > 0, do: "text-error"
  defp excess_class(_), do: "text-success"

  defp verdict_class("passed"), do: "text-success"
  defp verdict_class("failed"), do: "text-error"
  defp verdict_class(_), do: "text-muted"

  defp bp(nil, _n), do: "—"
  defp bp(v, n), do: "#{:erlang.float_to_binary(v / 1, decimals: 1)} (n=#{n})"

  defp ratio(nil), do: "—"
  defp ratio(v), do: :erlang.float_to_binary(v / 1, decimals: 2)

  defp stat(nil, _key), do: "—"

  defp stat(stats, key) do
    case Map.get(stats, key) do
      nil -> "—"
      v when is_float(v) -> :erlang.float_to_binary(v, decimals: 2)
      v -> to_string(v)
    end
  end

  defp date(nil), do: "—"
  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")
end
