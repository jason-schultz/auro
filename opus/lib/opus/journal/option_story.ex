defmodule Opus.Journal.OptionStory do
  @moduledoc """
  A closed options paper trade (`Opus.Options.Paper.closed_trades/1`) told in
  plain options terms for the Journal's Options tab: what was sold and
  bought, what it took in or paid, how it ended, and the result against the
  premium or the cost. Also the tab's headline numbers. Pure: no queries.

  Money is the paper books' US$, commissions in.
  """

  import OpusWeb.Format, only: [day: 1, money: 1, pct: 1, signed_money: 1, signed_pct: 1]

  @type story :: %{
          headline: String.t(),
          result: :win | :loss | :flat,
          story: [{String.t(), String.t()}],
          numbers: [{String.t(), String.t(), String.t() | nil}]
        }

  @doc "The trade's story: a headline, labelled lines and its numbers."
  @spec tell(map()) :: story()
  def tell(t) do
    %{
      headline: headline(t),
      result: result(t.pnl),
      story: [
        {"The trade", what(t)},
        {"Opened", "#{day(t.opened_on)}, #{opened_words(t.opened_cash)}"},
        {"How it ended", ended(t)}
      ],
      numbers: numbers(t)
    }
  end

  @doc """
  Headline numbers over `trades`: how many closed, how many made money,
  the P&L, and for trades that took in premium, the share of it kept.
  """
  @spec kpis([map()]) :: map()
  def kpis(trades) do
    credit = Enum.filter(trades, &(&1.opened_cash > 0 and &1.ended in [:closed, :expired]))
    taken = Enum.sum_by(credit, & &1.opened_cash)

    %{
      count: length(trades),
      won: Enum.count(trades, &(&1.pnl > 0)),
      pnl: Enum.sum_by(trades, & &1.pnl) / 1,
      kept: if(taken > 0, do: Enum.sum_by(credit, & &1.pnl) / taken)
    }
  end

  defp result(pnl) when pnl > 0, do: :win
  defp result(pnl) when pnl < 0, do: :loss
  defp result(_pnl), do: :flat

  defp headline(%{ended: :assigned} = t),
    do: "Assigned: #{shares(t)} shares bought at #{money(settled(t))}"

  defp headline(%{ended: :called_away} = t),
    do: "Called away: the shares sold at #{money(settled(t))}, #{signed_money(t.pnl)}"

  defp headline(%{opened_cash: taken} = t) when taken > 0 do
    if t.pnl >= 0,
      do: "Kept #{money(t.pnl)} of #{money(taken)} premium",
      else: "Lost #{money(-t.pnl)} against #{money(taken)} premium"
  end

  defp headline(%{opened_cash: paid} = t) when paid < 0,
    do: "#{signed_money(t.pnl)} on #{money(-paid)} paid (#{signed_pct(t.pnl / -paid)})"

  defp headline(t), do: signed_money(t.pnl)

  # "Sold the $265.00 put at $2.64 and bought the $250.00 put at $1.08,
  # expiring Dec 4" (shares lots by count).
  defp what(t) do
    {options, lots} = Enum.split_with(t.legs, &(&1.kind in ~w(put call)))

    legs =
      Enum.map(options, fn leg ->
        "#{verb(leg)} #{count(leg)}#{money(leg.strike)} #{leg.kind} at #{money(leg.open_price)}"
      end) ++ Enum.map(lots, &"held #{&1.quantity} shares bought at #{money(&1.open_price)}")

    expiry = options |> Enum.map(& &1.expiration) |> Enum.uniq()

    "#{t.symbol}: " <>
      join(legs) <>
      case expiry do
        [one] -> ", expiring #{day(one)}"
        _ -> ""
      end
  end

  defp verb(%{side: "short"}), do: "sold the"
  defp verb(_long), do: "bought the"

  defp count(%{quantity: n}) when n > 1, do: "#{n} × "
  defp count(_one), do: ""

  defp opened_words(cash) when cash > 0, do: "taking in #{money(cash)} after commissions"
  defp opened_words(cash) when cash < 0, do: "paying #{money(-cash)} with commissions"
  defp opened_words(_cash), do: "for nothing up front"

  defp ended(%{ended: :assigned} = t),
    do:
      "Assigned on #{day(t.closed_on)}: the put was exercised, so the book bought " <>
        "#{shares(t)} shares at #{money(settled(t))}. The premium is the option's result; " <>
        "the shares are a new trade."

  defp ended(%{ended: :called_away} = t),
    do:
      "Called away on #{day(t.closed_on)}: the call was exercised and the shares sold at #{money(settled(t))}."

  defp ended(%{ended: :expired} = t),
    do: "Ran to expiry on #{day(t.closed_on)}#{expiry_value(t)}."

  defp ended(t) do
    closes =
      t.legs
      |> Enum.filter(&(&1.kind in ~w(put call) and is_number(&1.close_price)))
      |> Enum.map(
        &"#{close_verb(&1)} the #{money(&1.strike)} #{&1.kind} at #{money(&1.close_price)}"
      )

    "Closed before expiry on #{day(t.closed_on)}: #{join(closes)}."
  end

  defp close_verb(%{side: "short"}), do: "bought back"
  defp close_verb(_long), do: "sold"

  defp expiry_value(t) do
    if Enum.all?(t.legs, &((&1.close_price || 0.0) == 0.0)),
      do: ", every leg worthless",
      else: ", settled at what each leg was worth then"
  end

  defp numbers(t) do
    held = Date.diff(t.closed_on, t.opened_on)

    [
      opened_number(t.opened_cash),
      {"Result", signed_money(t.pnl), share_note(t)},
      {"Held", "#{held} #{if held == 1, do: "day", else: "days"}", nil}
    ]
  end

  defp opened_number(cash) when cash >= 0, do: {"Premium taken in", money(cash), nil}
  defp opened_number(cash), do: {"Paid", money(-cash), nil}

  defp share_note(%{ended: ended}) when ended in [:assigned, :called_away], do: nil

  defp share_note(%{opened_cash: taken, pnl: pnl}) when taken > 0,
    do: "#{pct(pnl / taken)} of the premium kept"

  defp share_note(%{opened_cash: paid, pnl: pnl}) when paid < 0,
    do: "#{signed_pct(pnl / -paid)} on the cost"

  defp share_note(_t), do: nil

  defp settled(t),
    do: Enum.find_value(t.legs, &(&1.status in ~w(assigned called_away) && &1.strike))

  defp shares(t) do
    t.legs
    |> Enum.find(&(&1.status in ~w(assigned called_away) and &1.kind in ~w(put call)))
    |> then(&((&1 && &1.quantity * 100) || 100))
  end

  defp join([]), do: ""
  defp join([one]), do: one
  defp join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
