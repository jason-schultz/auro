defmodule Opus.Journal.Cards do
  @moduledoc """
  The Journal's five summary cards, the same on every tab, each tab filling
  them from its own records: the result over the last 30 days, the worst
  drop, what trading costs, how trades end, and this week. With each tab's
  value over time for its line (`OpusWeb.Components.ValueLine`).

    * OANDA: the live trades (CAD) and the account's daily value.
    * Options: the paper books' closed trades (US$) and their running
      closed-trade P&L (the books' daily value isn't kept).
    * Holdings: the hand-entered Wealthsimple holdings at each close
      (`Opus.Accounts.Snapshots`).

  A card a tab has nothing for says why instead of a number.
  """

  import Ecto.Query
  import OpusWeb.Format, only: [money: 1, pct: 1, signed_money: 1]

  alias Opus.Accounts.Snapshots
  alias Opus.{Clock, Journal, Repo}
  alias Opus.Journal.OptionStory
  alias Opus.Options.Paper

  @days 30

  @type card :: %{
          title: String.t(),
          value: String.t(),
          note: String.t() | nil,
          tone: number() | nil
        }
  @type tab :: %{cards: [card()], line: [%{on: Date.t(), value: float()}], line_label: String.t()}

  @doc "The OANDA tab's cards and line."
  @spec oanda() :: tab()
  def oanda do
    window = Journal.window(@days)
    kpis = Journal.kpis(window)
    week = Journal.kpis(this_week())
    line = Journal.nav_by_day()

    %{
      line: line,
      line_label: "OANDA account value (CAD)",
      cards: [
        %{
          title: "Last #{@days} days",
          value: signed_money(kpis.total_pnl_cad),
          note: "#{kpis.trade_count} closed, #{pct(kpis.win_rate_pct / 100)} won",
          tone: kpis.total_pnl_cad
        },
        drop_card(line, "account value"),
        slippage_card(Journal.execution_quality(Journal.window(90))),
        ends_card(Journal.exit_counts(window), "No trades closed in #{@days} days"),
        %{
          title: "This week",
          value: signed_money(week.total_pnl_cad),
          note: "#{week.trade_count} closed",
          tone: week.total_pnl_cad
        }
      ]
    }
  end

  @doc "The Options tab's cards and line."
  @spec options() :: tab()
  def options do
    closed = Paper.closed_trades(1_000)
    since = Date.add(Clock.today(), -@days)
    recent = Enum.filter(closed, &(Date.compare(&1.closed_on, since) != :lt))
    monday = Date.beginning_of_week(Clock.today())
    week = Enum.filter(closed, &(Date.compare(&1.closed_on, monday) != :lt))
    kpis = OptionStory.kpis(recent)
    line = running_pnl(closed)

    %{
      line: line,
      line_label: "Closed-trade P&L, all books (US$)",
      cards: [
        %{
          title: "Last #{@days} days",
          value: signed_money(kpis.pnl),
          note: "#{kpis.count} closed, #{kpis.won} made money",
          tone: kpis.pnl
        },
        money_drop_card(line),
        %{
          title: "Costs",
          value: money(recent |> Enum.flat_map(& &1.legs) |> Enum.sum_by(& &1.commission)),
          note: "commissions on the last #{@days} days' trades; the spread is in the fills",
          tone: nil
        },
        ends_card(
          recent |> Enum.frequencies_by(&ended_word(&1.ended)) |> Enum.sort_by(&(-elem(&1, 1))),
          "No trades closed in #{@days} days"
        ),
        %{
          title: "This week",
          value: signed_money(Enum.sum_by(week, & &1.pnl) / 1),
          note: "#{length(week)} closed",
          tone: Enum.sum_by(week, & &1.pnl)
        }
      ]
    }
  end

  @doc "The Holdings tab's cards and line."
  @spec holdings() :: tab()
  def holdings do
    history = Snapshots.history(365)
    summary = Snapshots.summary(history)
    latest = List.last(history)
    week = Snapshots.change_since(Date.beginning_of_week(Clock.today()))
    line = Enum.map(history, &Map.take(&1, [:on, :value]))

    %{
      line: line,
      line_label: "Holdings value",
      cards: [
        if(latest,
          do: %{
            title: "At the last close",
            value: money(latest.value),
            note: "#{signed_money(latest.value - latest.cost)} against cost",
            tone: latest.value - latest.cost
          },
          else: none("At the last close", "Recorded from the next close")
        ),
        if(summary,
          do: %{
            title: "Worst drop",
            value: pct(summary.worst_drawdown),
            note: "#{pct(summary.drawdown)} below the high now",
            tone: nil
          },
          else: none("Worst drop", "Needs two closes")
        ),
        spread_card(),
        none("How trades end", "Bought and sold by hand at Wealthsimple"),
        if(week,
          do: %{
            title: "This week",
            value: signed_money(week.change),
            note: "since the close before Monday",
            tone: week.change
          },
          else: none("This week", "Needs a close before this week")
        )
      ]
    }
  end

  # Monday midnight New York to now.
  defp this_week,
    do: {Clock.midnight(Date.beginning_of_week(Clock.today())), DateTime.utc_now()}

  defp none(title, why), do: %{title: title, value: "—", note: why, tone: nil}

  # The fall from the highest value: the worst over the line, and now.
  defp drop_card([_, _ | _] = line, what) do
    {peak, worst} =
      Enum.reduce(line, {0.0, 0.0}, fn %{value: v}, {peak, worst} ->
        peak = max(peak, v)
        {peak, max(worst, if(peak > 0, do: 1 - v / peak, else: 0.0))}
      end)

    now = if peak > 0, do: 1 - List.last(line).value / peak, else: 0.0

    %{
      title: "Worst drop",
      value: pct(worst),
      note: "of the #{what}, last year; #{pct(now)} below the high now",
      tone: nil
    }
  end

  defp drop_card(_line, _what), do: none("Worst drop", "Needs two days of values")

  # A running P&L has no base to divide by: its worst fall in money.
  defp money_drop_card([_, _ | _] = line) do
    {_peak, worst} =
      Enum.reduce(line, {0.0, 0.0}, fn %{value: v}, {peak, worst} ->
        peak = max(peak, v)
        {peak, max(worst, peak - v)}
      end)

    %{
      title: "Worst drop",
      value: money(-worst),
      note: "in closed-trade P&L, from its high",
      tone: nil
    }
  end

  defp money_drop_card(_line), do: none("Worst drop", "Needs two days of closes")

  # Fills against the backtest's assumed fills, averaged over every
  # strategy's measured round trips.
  defp slippage_card(rows) do
    measured =
      Enum.filter(rows, &(is_number(&1.mean_round_trip_excess_bp) and &1.entries_measured > 0))

    weight = Enum.sum_by(measured, & &1.entries_measured)

    if weight > 0 do
      bp = Enum.sum_by(measured, &(&1.mean_round_trip_excess_bp * &1.entries_measured)) / weight

      %{
        title: "Costs",
        value: "#{:erlang.float_to_binary(bp / 1, decimals: 1)} bp",
        note:
          "a round trip #{if bp > 0, do: "worse", else: "better"} than the backtest assumed (90 days)",
        tone: -bp
      }
    else
      none("Costs", "No measured fills yet")
    end
  end

  # The holdings' measured spreads (`Opus.MarketData.SpreadWorker`).
  defp spread_card do
    spreads =
      from(p in "wealthsimple_positions",
        join: i in "instruments",
        on: i.id == p.instrument_id,
        where: p.shares > 0 and not is_nil(i.spread_bps),
        select: i.spread_bps
      )
      |> Repo.all()

    case spreads do
      [] ->
        none("Costs", "Spreads not measured yet: 10 bp a round trip assumed")

      _ ->
        bp = Enum.sum(spreads) / length(spreads)

        %{
          title: "Costs",
          value: "#{:erlang.float_to_binary(bp / 1, decimals: 1)} bp",
          note: "a round trip in spread, the holdings' average (measured)",
          tone: nil
        }
    end
  end

  defp ends_card([], why), do: none("How trades end", why)

  defp ends_card([{top, n} | rest], _why) do
    total = n + Enum.sum_by(rest, &elem(&1, 1))

    %{
      title: "How trades end",
      value: top,
      note:
        "#{n} of #{total}" <>
          Enum.map_join(Enum.take(rest, 2), "", fn {label, k} -> " · #{label} #{k}" end),
      tone: nil
    }
  end

  defp ended_word(:assigned), do: "Assigned"
  defp ended_word(:called_away), do: "Called away"
  defp ended_word(:expired), do: "Expired"
  defp ended_word(:closed), do: "Closed early"

  # Closed-trade P&L added up by the day each closed.
  defp running_pnl(closed) do
    closed
    |> Enum.group_by(& &1.closed_on)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map_reduce(0.0, fn {on, trades}, total ->
      total = total + Enum.sum_by(trades, & &1.pnl)
      {%{on: on, value: total}, total}
    end)
    |> elem(0)
  end
end
