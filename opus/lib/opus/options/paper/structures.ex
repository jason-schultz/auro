defmodule Opus.Options.Paper.Structures do
  @moduledoc """
  The defined-risk credit books (research/options_paper_engine.md, v2) as
  pure functions over one underlying's open trade and one night's snapshot:

    * **put credit spread:** sell the put nearest −0.25 delta and buy the
      put nearest −0.10 below it, same expiry;
    * **iron condor:** sell the put nearest −0.16 and the call nearest
      +0.16, buy the put nearest −0.05 below and the call nearest +0.05
      above, all on the short put's expiry.

  Both buy the whole structure back once it costs half the credit or less,
  or at 21 days to expiry whatever its value; one still open at expiry
  settles every leg at its intrinsic value in cash. A trade reserves its
  maximum loss, and every leg must be fillable to open or close.
  """

  alias Opus.Options.Paper.{Legs, Pick}

  @take_profit 0.5
  @manage_dte 21

  @type trade :: %{legs: [map()]}

  @doc "The legs to open for `structure` from a night's chain, or nil."
  @spec entry(String.t(), [map()]) :: [map()] | nil
  def entry("put_spread", chain) do
    with %{} = short <- Pick.nearest(chain, "put", -0.25),
         %{} = long <-
           Pick.nearest(
             chain,
             "put",
             -0.10,
             &(same_expiry?(&1, short) and &1.strike < short.strike)
           ) do
      credit_only([Legs.open_leg("long", long), Legs.open_leg("short", short)])
    else
      _ -> nil
    end
  end

  def entry("iron_condor", chain) do
    with %{} = short_put <- Pick.nearest(chain, "put", -0.16),
         %{} = short_call <- Pick.nearest(chain, "call", 0.16, &same_expiry?(&1, short_put)),
         %{} = long_put <-
           Pick.nearest(
             chain,
             "put",
             -0.05,
             &(same_expiry?(&1, short_put) and &1.strike < short_put.strike)
           ),
         %{} = long_call <-
           Pick.nearest(
             chain,
             "call",
             0.05,
             &(same_expiry?(&1, short_put) and &1.strike > short_call.strike)
           ) do
      credit_only([
        Legs.open_leg("long", long_put),
        Legs.open_leg("short", short_put),
        Legs.open_leg("short", short_call),
        Legs.open_leg("long", long_call)
      ])
    else
      _ -> nil
    end
  end

  defp same_expiry?(row, other), do: row.expiration == other.expiration

  # A credit book only opens for a credit.
  defp credit_only(legs), do: if(Legs.net_premium(legs) > 0, do: legs)

  @doc "Cash a trade sets aside: its maximum loss."
  @spec collateral(trade() | [map()]) :: float()
  def collateral(%{legs: legs}), do: collateral(legs)
  def collateral(legs), do: Legs.summary(legs).max_loss || 0.0

  @doc "What to do with an open trade tonight."
  @spec manage(trade(), %{integer() => map()}, map()) :: tuple()
  def manage(%{legs: [%{expiration: expiration} | _]} = trade, quotes, snapshot) do
    case Legs.expiry_state(expiration, snapshot) do
      {:open, dte} -> manage_open(trade, quotes, dte)
      {:settle, close} -> {:settle, trade, close}
      :awaiting_close -> {:hold, trade}
    end
  end

  defp manage_open(trade, quotes, dte) do
    case take_profit(trade, quotes) do
      {:close, _trade, _fills} = close ->
        close

      {:hold, trade} ->
        case fills(trade, quotes) do
          fills when is_list(fills) and dte <= @manage_dte -> {:close, trade, fills}
          _ -> {:hold, trade}
        end
    end
  end

  @doc """
  The take-profit on its own, as the resting order a broker would hold:
  the whole trade bought back once it costs half the credit or less, with
  every leg fillable. Checked by the daily rules and on every intraday
  quote.
  """
  @spec take_profit(trade(), %{integer() => map()}) :: tuple()
  def take_profit(trade, quotes) do
    with fills when is_list(fills) <- fills(trade, quotes),
         debit = Enum.sum_by(fills, fn {leg, price} -> Legs.sign(leg) * price * leg.quantity end),
         true <- debit <= Legs.net_premium(trade.legs) * (1 - @take_profit) do
      {:close, trade, fills}
    else
      _ -> {:hold, trade}
    end
  end

  # The price each leg closes at, or nil unless every leg is fillable.
  defp fills(trade, quotes) do
    quoted = Enum.map(trade.legs, &{&1, Map.get(quotes, &1.contract_id)})

    if Enum.all?(quoted, fn {_leg, quote} -> Pick.fillable?(quote) end),
      do: Enum.map(quoted, fn {leg, quote} -> {leg, Legs.close_price(leg, quote)} end)
  end

  @doc """
  Tonight's actions for one underlying: manage the open trade, then, with
  nothing left open, open a new one if its maximum loss fits in the book's
  `available` cash (cash less what open trades reserve), counting what
  tonight's close or settlement freed.
  """
  @spec plan(String.t(), trade() | nil, map(), float(), float()) :: [tuple()]
  def plan(structure, trade, snapshot, available, commission) do
    managed = if trade, do: [manage(trade, snapshot.quotes, snapshot)], else: []

    if Enum.any?(managed, &match?({:hold, _}, &1)) do
      managed
    else
      available =
        Enum.reduce(managed, available, fn {_tag, trade, _} = action, acc ->
          acc + Legs.cash(action, commission) + collateral(trade)
        end)

      managed ++ open(structure, snapshot.chain, available)
    end
  end

  defp open(structure, chain, available) do
    case entry(structure, chain) do
      nil -> []
      legs -> if collateral(legs) <= available, do: [{:open, structure, legs}], else: []
    end
  end
end
