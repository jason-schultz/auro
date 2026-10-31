defmodule OpusWeb.JournalLive do
  @moduledoc """
  Journal: the weekly forward-test review in one place. Thirty-day KPIs,
  the latest trades beside the chosen one's story in plain words, filtered
  by strategy (`OpusWeb.Components.TradeStory`), execution quality against
  the backtest's assumed fills, holdout verdicts, open circuit-breaker suspensions and the
  frozen weekly digests. The Options tab (`?tab=options`) has the options
  paper books' closed trades in options terms
  (`OpusWeb.Components.OptionJournal`).

  Everything is read from the database on mount; nothing here is pushed by
  price events.
  """
  use OpusWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import OpusWeb.Format
  import OpusWeb.Components.TradeStory
  import OpusWeb.Components.OptionJournal
  import OpusWeb.Components.ValueLine

  alias Opus.Journal
  alias Opus.Journal.{Cards, Digest}
  alias Opus.Options.Paper
  alias Opus.Repo

  @kpi_days 30
  @execution_days 90
  @recent_trades 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Journal", kpi_days: @kpi_days, execution_days: @execution_days)
     |> load()
     |> paper_accounts(connected?(socket))}
  end

  defp load(socket) do
    kpi_window = Journal.window(@kpi_days)

    assign(socket,
      kpis: Journal.kpis(kpi_window),
      strategies: Journal.traded_strategies(kpi_window),
      option_trades: Paper.closed_trades(@recent_trades),
      execution: Journal.execution_quality(Journal.window(@execution_days)),
      holdouts: Journal.holdout_verdicts(),
      suspensions: Journal.open_suspensions(),
      digests: Repo.all(from(d in Digest, order_by: [desc: d.week_start], limit: 12)),
      as_of: DateTime.utc_now()
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    strategy = params["strategy"]
    trades = Journal.recent_trades(@recent_trades, strategy)

    # The chosen trade, or the newest in the list so the story is never empty.
    trade =
      (params["trade"] && Journal.trade(params["trade"])) ||
        (trades != [] && Journal.trade(hd(trades).id)) || nil

    option =
      Enum.find(socket.assigns.option_trades, &(to_string(&1.id) == params["option"])) ||
        List.first(socket.assigns.option_trades)

    tab = if params["tab"] in ~w(options holdings), do: params["tab"], else: "oanda"

    {:noreply,
     assign(socket,
       tab: tab,
       board: board_for(tab),
       strategy: strategy,
       trades: trades,
       trade: trade,
       option: option
     )}
  end

  # Whether the OANDA account is practice money, for its tab's "paper" tag:
  # from the last accounts overview, or asked for once in the background.
  defp paper_accounts(socket, connected) do
    case Opus.Dashboard.cached_accounts() do
      {overview, _at} ->
        assign(socket, oanda_paper: oanda_paper?(overview))

      nil when connected ->
        socket |> assign(oanda_paper: nil) |> start_async(:accounts, &Opus.Dashboard.accounts/0)

      nil ->
        assign(socket, oanda_paper: nil)
    end
  end

  # An overview cached before accounts carried `paper` reads as not paper.
  defp oanda_paper?(overview),
    do: Enum.any?(overview.accounts, &(&1.broker == "OANDA" and Map.get(&1, :paper, false)))

  @impl true
  def handle_async(:accounts, {:ok, {:ok, overview}}, socket),
    do: {:noreply, assign(socket, oanda_paper: oanda_paper?(overview))}

  def handle_async(:accounts, _failed, socket), do: {:noreply, socket}

  # The tab's five cards and its line (`Opus.Journal.Cards`).
  defp board_for("options"), do: Cards.options()
  defp board_for("holdings"), do: Cards.holdings()
  defp board_for(_oanda), do: Cards.oanda()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-12">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h1 class="text-[22px] font-semibold tracking-tight"><.t {copy("Journal")} /></h1>
          <span class="text-[13px] text-muted">
            <.t {copy("Closed trades")} />, last {@kpi_days} days · {clock(@as_of)}
          </span>
        </header>

        <nav aria-label="Journal" class="-mt-6 flex gap-2 text-[14px]">
          <.link
            patch={~p"/journal"}
            class={chip_class(@tab == "oanda")}
          >
            <.t {copy("OANDA trades")} />
            <.paper_tag :if={@oanda_paper} />
          </.link>
          <.link
            patch={~p"/journal?tab=options"}
            class={chip_class(@tab == "options")}
          >
            <.t {copy("Options")} /> <.paper_tag />
          </.link>
          <.link
            patch={~p"/journal?tab=holdings"}
            class={chip_class(@tab == "holdings")}
          >
            <.t {copy("Holdings")} />
          </.link>
        </nav>

        <.board board={@board} tab={@tab} />

        <div :if={@tab == "holdings"} class="flex flex-col gap-3">
          <p class="m-0 text-[14px] text-muted">
            The Wealthsimple holdings are bought and sold by hand; their closes, the day's moves and
            the last ten days against cost are on the <.link
              navigate={~p"/accounts"}
              class="text-primary hover:underline"
            >Accounts page</.link>,
            where they're edited too.
          </p>
        </div>

        <div :if={@tab == "options"} class="flex flex-col gap-12">
          <.section
            title={copy("Options trades")}
            hint={
              copy("Paper options books, the latest %{count} closed, newest first. US$.",
                count: length(@option_trades)
              )
            }
          >
            <div
              :if={@option_trades != []}
              class="grid items-start gap-4 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]"
            >
              <.option_list trades={@option_trades} selected={@option && @option.id} />
              <div class="lg:sticky lg:top-28">
                <.option_panel :if={@option} trade={@option} />
              </div>
            </div>
            <.empty :if={@option_trades == []}>
              <.t {copy("No options trade has closed yet.")} />
            </.empty>
          </.section>
        </div>

        <div :if={@tab == "oanda"} class="flex flex-col gap-12">
          <.kpis kpis={@kpis} />

          <.section
            title={pcopy("section", "Trades")}
            hint={
              copy("The latest %{count}, newest first. Strategy records cover the last %{days} days.",
                count: length(@trades),
                days: @kpi_days
              )
            }
          >
            <.strategy_filter :if={@strategies != []} strategies={@strategies} selected={@strategy} />
            <div
              :if={@trades != []}
              class="grid items-start gap-4 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]"
            >
              <.trade_list trades={@trades} selected={@trade && @trade.id} strategy={@strategy} />
              <div class="lg:sticky lg:top-28 lg:max-h-[calc(100vh-8rem)] lg:overflow-y-auto">
                <.trade_panel :if={@trade} trade={@trade} />
              </div>
            </div>
            <.empty :if={@trades == []}>
              <.t {copy("No live trades yet.")} />
            </.empty>
          </.section>

          <.section
            title={copy("Execution quality")}
            hint={
              copy(
                "Fills vs the backtest's assumed fills, last %{days} days. Positive = worse than backtest.",
                days: @execution_days
              )
            }
          >
            <.review_table
              :if={@execution != []}
              cols={[
                {copy("Strategy"), :left},
                {copy("Trades"), :right},
                {copy("Entry slip (bp)"), :right},
                {copy("Exit slip (bp)"), :right},
                {copy("Spread (bp)"), :right},
                {copy("Round trip excess (bp)"), :right}
              ]}
            >
              <tr :for={e <- @execution}>
                <td class="py-2.5"><.strategy_label row={e} /></td>
                <td class="py-2.5 text-right">{e.trades}</td>
                <td class="py-2.5 text-right">{bp(e.mean_entry_slippage_bp, e.entries_measured)}</td>
                <td class="py-2.5 text-right">{bp(e.mean_exit_slippage_bp, e.exits_measured)}</td>
                <td class="py-2.5 text-right">{bp(e.mean_spread_bp, e.entries_measured)}</td>
                <td class={[
                  "py-2.5 text-right font-medium",
                  excess_class(e.mean_round_trip_excess_bp)
                ]}>
                  {bp(e.mean_round_trip_excess_bp, min(e.entries_measured, e.exits_measured))}
                </td>
              </tr>
            </.review_table>
            <.empty :if={@execution == []}>
              <.t {copy("No measured fills yet. Rows appear as strategies trade.")} />
            </.empty>
          </.section>

          <.section
            title={copy("Holdout verdicts")}
            hint={copy("The pipeline's one look at bars after the holdout start.")}
          >
            <.review_table
              :if={@holdouts != []}
              cols={[
                {copy("Config"), :left},
                {copy("Verdict"), :left},
                {copy("Sharpe (a year)"), :right},
                {copy("Trades"), :right},
                {copy("When"), :right}
              ]}
            >
              <tr :for={h <- @holdouts}>
                <td class="py-2.5"><.strategy_label row={h} /></td>
                <td class={["py-2.5", verdict_class(h.status)]}>
                  {h.status}
                  <span :if={h.failure_reason} class="text-muted"> · {h.failure_reason}</span>
                </td>
                <td class="py-2.5 text-right">{stat(h.stats, "annual_sharpe")}</td>
                <td class="py-2.5 text-right">{stat(h.stats, "num_trades")}</td>
                <td class="py-2.5 text-right text-muted">{day(h.evaluated_at)}</td>
              </tr>
            </.review_table>
            <.empty :if={@holdouts == []}>
              <.t {copy("No holdout runs yet.")} />
            </.empty>
          </.section>

          <.section
            title={pcopy("section", "Suspended")}
            hint={copy("Circuit-breaker suspensions awaiting a manual reset.")}
          >
            <.review_table
              :if={@suspensions != []}
              cols={[{copy("Strategy"), :left}, {copy("Trigger"), :left}, {copy("Since"), :right}]}
            >
              <tr :for={s <- @suspensions}>
                <td class="py-2.5"><.strategy_label row={s} /></td>
                <td class="py-2.5">
                  {s.trigger_kind} <span class="text-muted">· {s.trigger_detail}</span>
                </td>
                <td class="py-2.5 text-right text-muted">{day(s.triggered_at)}</td>
              </tr>
            </.review_table>
            <.empty :if={@suspensions == []}>
              <.t {copy("Nothing suspended.")} />
            </.empty>
          </.section>

          <.section
            title={copy("Weekly digests")}
            hint={copy("Frozen every Monday 08:00 ET for the week before.")}
          >
            <.review_table
              :if={@digests != []}
              cols={[
                {copy("Week of"), :left},
                {copy("Trades"), :right},
                {copy("Win rate"), :right},
                {pcopy("column", "P&L"), :right},
                {copy("Profit factor"), :right}
              ]}
            >
              <tr :for={d <- @digests}>
                <td class="py-2.5">{d.week_start}</td>
                <td class="py-2.5 text-right">{d.payload["kpis"]["trade_count"]}</td>
                <td class="py-2.5 text-right">
                  {pct((d.payload["kpis"]["win_rate_pct"] || 0) / 100)}
                </td>
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
              <.t {copy("First digest lands next Monday.")} />
            </.empty>
          </.section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :board, :map, required: true, doc: "Cards.oanda/0, options/0 or holdings/0"
  attr :tab, :string, required: true

  # The same five cards on every tab, then the tab's value over time.
  defp board(assigns) do
    ~H"""
    <section class="flex flex-col gap-4" aria-label="Summary">
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <div
          :for={card <- @board.cards}
          class="flex min-h-28 flex-col gap-1 rounded-box border border-base-300 bg-base-200 px-4 py-3"
        >
          <span class="text-[12px] text-muted">{card.title}</span>
          <span class={["text-xl font-semibold tracking-tight", pnl_class(card.tone)]}>
            {card.value}
          </span>
          <span :if={card.note} class="text-[12px] text-muted">{card.note}</span>
        </div>
      </div>
      <div class="flex flex-col gap-2">
        <span class="text-[14px] font-medium">{@board.line_label}</span>
        <.value_line
          id={"journal-line-#{@tab}"}
          points={@board.line}
          label={@board.line_label}
          empty="Not enough recorded yet to draw a line: it starts with the second day."
        />
      </div>
    </section>
    """
  end

  attr :kpis, :map, required: true

  defp kpis(assigns) do
    ~H"""
    <section class="grid grid-cols-2 gap-x-8 gap-y-6 sm:grid-cols-3 lg:grid-cols-6">
      <.kpi label={copy("Trades")} value={@kpis.trade_count} />
      <.kpi label={copy("Win rate")} value={pct(@kpis.win_rate_pct / 100)} />
      <.kpi
        label={pcopy("total", "P&L")}
        value={money(@kpis.total_pnl_cad)}
        class={pnl_class(@kpis.total_pnl_cad)}
      />
      <.kpi label={copy("Profit factor")} value={ratio(@kpis.profit_factor)} />
      <.kpi
        label={copy("Expectancy")}
        value={money(@kpis.expectancy_cad)}
        class={pnl_class(@kpis.expectancy_cad)}
      />
      <.kpi
        label={copy("MFE / MAE")}
        value={"#{pct(@kpis.avg_mfe_pct, 2)} / #{pct(@kpis.avg_mae_pct, 2)}"}
      />
    </section>
    """
  end

  attr :label, :map, required: true, doc: "copy/1"
  attr :value, :any, required: true
  attr :class, :any, default: nil

  defp kpi(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-[13px] text-muted"><.t {@label} /></span>
      <span class={["text-2xl font-semibold tracking-tight", @class]}>{@value}</span>
    </div>
    """
  end

  attr :title, :map, required: true, doc: "copy/1"
  attr :hint, :map, default: nil, doc: "copy/1"
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section class="flex flex-col gap-3">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <span class="text-[15px] font-semibold"><.t {@title} /></span>
        <span :if={@hint} class="text-[13px] text-muted"><.t {@hint} /></span>
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
              :for={{label, align} <- @cols}
              class={[
                "border-b border-base-300 py-2.5 font-medium",
                align == :right && "text-right",
                align == :left && "text-left"
              ]}
            >
              <.t {label} />
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
end
