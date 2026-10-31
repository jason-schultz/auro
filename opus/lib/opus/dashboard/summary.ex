defmodule Opus.Dashboard.Summary do
  @moduledoc """
  The day's and the week's write-up for Discord (`Opus.Dashboard.NotifyWorker`),
  built from the database in plain words, no AI: what the live strategies
  closed and made, what the options paper books opened and closed, where
  the Wealthsimple holdings stand against their cost, and what is waiting
  on you.

  A day runs from midnight New York to `now`; a week from Monday midnight
  New York. Money is in each place's own currency: the OANDA account's
  CAD, the paper books' US$, the holdings' listing currency.
  """

  import Ecto.Query
  import OpusWeb.Format, only: [day: 1, money: 1, signed_money: 1, signed_pct: 1]

  alias Opus.{Clock, Journal, Repo}
  alias Opus.Accounts.Snapshots
  alias Opus.Options.Paper
  alias Opus.Options.Paper.Trade

  @type period :: :day | :week

  @doc """
  The title and lines for `period` ending `now`, from what the dashboard
  gathered (`Opus.Dashboard.gather/1`) and its alerts.
  """
  @spec build(period(), map(), [map()], DateTime.t()) :: {String.t(), [String.t()]}
  def build(period, gathered, alerts, now) do
    {from_date, to_date} = dates(period, now)
    urgent = Enum.filter(alerts, &(&1.level in [:act, :check]))

    title =
      "#{heading(period, from_date, to_date)}: " <>
        if(urgent == [], do: "all quiet", else: "#{length(urgent)} to look at")

    lines =
      [engine_line(gathered.input.engine)] ++
        live_lines({Clock.midnight(from_date), now}, gathered.live.open_trades) ++
        options_lines(from_date, to_date, gathered.books) ++
        holdings_lines(from_date) ++
        urgent_lines(urgent)

    {title, lines}
  end

  @doc "The New York dates `period` covers, ending on `now`'s."
  @spec dates(period(), DateTime.t()) :: {Date.t(), Date.t()}
  def dates(:day, now), do: {Clock.date(now), Clock.date(now)}

  def dates(:week, now) do
    today = Clock.date(now)
    {Date.beginning_of_week(today), today}
  end

  defp heading(:day, date, _), do: "Auro day, #{day(date)}"
  defp heading(:week, from, to), do: "Auro week, #{day(from)} to #{day(to)}"

  defp engine_line(:up), do: "Engine: running"
  defp engine_line({:down, _reason}), do: "Engine: NOT running"
  defp engine_line(:unknown), do: "Engine: couldn't check (see the alerts)"

  # The live strategies (OANDA, CAD): closed trades in the window, the best
  # and worst, and what's open now.
  defp live_lines(window, open) do
    kpis = Journal.kpis(window)
    open_line = "Open now: #{open}"

    case kpis.trade_count do
      0 ->
        ["**Live (OANDA):** no trades closed. #{open_line}"]

      n ->
        [
          "**Live (OANDA):** #{n} closed, #{kpis.win_count} won, " <>
            "#{signed_money(kpis.total_pnl_cad)} CAD. #{open_line}"
          | best_and_worst(window)
        ]
    end
  end

  defp best_and_worst({from_ts, to_ts}) do
    closed =
      from(t in "live_trades",
        where:
          t.status == "closed" and t.exit_time >= ^from_ts and t.exit_time <= ^to_ts and
            not is_nil(t.pnl),
        order_by: [desc: t.pnl],
        select: %{instrument: t.instrument, direction: t.direction, pnl: t.pnl}
      )
      |> Repo.all()

    case closed do
      [] -> []
      [only] -> ["  #{trade_words(only)}"]
      [best | rest] -> ["  Best: #{trade_words(best)} · worst: #{trade_words(List.last(rest))}"]
    end
  end

  defp trade_words(t),
    do: "#{t.instrument} #{String.downcase(t.direction)} #{signed_money(t.pnl)}"

  # The options paper books (US$): what opened and closed in the window,
  # each close in a few words, and the books' running total.
  defp options_lines(from_date, to_date, books) do
    opened =
      Repo.one(
        from(t in Trade,
          where: t.opened_on >= ^from_date and t.opened_on <= ^to_date,
          select: count()
        )
      )

    closed =
      Paper.closed_trades(100)
      |> Enum.filter(&(Date.compare(&1.closed_on, from_date) != :lt))

    total = Enum.sum_by(books, &(&1.pnl || 0.0))

    head =
      "**Options (paper, US$):** #{opened} opened, #{length(closed)} closed" <>
        closed_total(closed) <> ". All books so far: #{signed_money(total)}"

    [
      head
      | Enum.map(
          closed,
          &"  #{&1.symbol} #{String.replace(&1.structure, "_", " ")} #{ended(&1)} #{signed_money(&1.pnl)}"
        )
    ]
  end

  defp closed_total([]), do: ""
  defp closed_total(closed), do: " (#{signed_money(Enum.sum_by(closed, & &1.pnl))})"

  defp ended(%{ended: :assigned}), do: "assigned:"
  defp ended(%{ended: :called_away}), do: "called away:"
  defp ended(%{ended: :expired}), do: "expired:"
  defp ended(%{ended: :closed}), do: "closed:"

  # The Wealthsimple holdings at their latest price against what they cost,
  # and their move since the close before the period (`Snapshots`).
  defp holdings_lines(from_date) do
    held =
      Repo.all(
        from(p in "wealthsimple_positions",
          where: p.shares > 0 and not is_nil(p.current_price),
          select: %{shares: p.shares, price: p.current_price, cost: p.avg_cost}
        )
      )

    value = Enum.sum_by(held, &(&1.shares * &1.price))
    cost = held |> Enum.filter(& &1.cost) |> Enum.sum_by(&(&1.shares * &1.cost))

    cond do
      held == [] ->
        []

      cost > 0 ->
        [
          "**Holdings (Wealthsimple):** #{length(held)} worth #{money(value)}, " <>
            "#{signed_money(value - cost)} (#{signed_pct(value / cost - 1)}) against cost" <>
            moved(Snapshots.change_since(from_date))
        ]

      true ->
        ["**Holdings (Wealthsimple):** #{length(held)} worth #{money(value)}"]
    end
  end

  defp moved(%{change: change, pct: pct}) when is_number(pct),
    do: "; moved #{signed_money(change)} (#{signed_pct(pct)}) since the close before"

  defp moved(_none), do: ""

  defp urgent_lines([]), do: []

  defp urgent_lines(urgent),
    do: ["**To look at:**" | Enum.map(urgent, &"• #{&1.title}")]
end
