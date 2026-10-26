defmodule Opus.Options.Paper.LongOptions do
  @moduledoc """
  The books that buy options (research/options_paper_engine.md, v2), as
  pure functions over one underlying's open trades and one night's snapshot:

    * **ideas:** buy one contract of each new dip-buy call the nightly scan
      flags, at most 5 open across the book and at most US$2,000 of premium
      each; sell at double the price paid, at half of it, or at 21 days to
      expiry;
    * **crash puts:** hold one put nearest −0.10 delta; at 21 days to expiry
      sell it and buy the next month's (a roll), with no take-profit.

  Buys are at the ask and sales at the bid; a long option still open at
  expiry settles at its intrinsic value. The premium paid is all it can
  lose, so nothing is reserved.
  """

  alias Opus.Options.Paper.{Legs, Pick}

  @manage_dte 21
  @max_open 5
  @max_premium 2_000.0
  @crash_delta -0.10

  @doc "What to do with one open long option tonight."
  @spec manage(String.t(), map(), %{integer() => map()}, map()) :: tuple()
  def manage(
        book,
        %{legs: [%{expiration: expiration} = leg]} = trade,
        quotes,
        %{as_of: as_of} = s
      ) do
    if Date.compare(as_of, expiration) == :lt,
      do:
        exit_rule(
          book,
          trade,
          leg,
          Map.get(quotes, leg.contract_id),
          Date.diff(expiration, as_of)
        ),
      else: {:settle, trade, Map.get(s.expiry_spots, expiration, s.spot)}
  end

  defp exit_rule(book, trade, leg, quote, dte) do
    cond do
      not Pick.fillable?(quote) -> {:hold, trade}
      dte <= @manage_dte -> {:close, trade, [{leg, quote.bid}]}
      book == "ideas" and quote.bid >= leg.open_price * 2 -> {:close, trade, [{leg, quote.bid}]}
      book == "ideas" and quote.bid <= leg.open_price * 0.5 -> {:close, trade, [{leg, quote.bid}]}
      true -> {:hold, trade}
    end
  end

  @doc """
  Crash puts tonight: manage the open put, and with none left open buy the
  put nearest −0.10 delta if the book's cash covers it.
  """
  @spec plan_crash_puts([map()], map(), float(), float()) :: [tuple()]
  def plan_crash_puts(trades, snapshot, available, commission) do
    managed = Enum.map(trades, &manage("crash_puts", &1, snapshot.quotes, snapshot))

    if Enum.any?(managed, &match?({:hold, _}, &1)) do
      managed
    else
      available = Enum.reduce(managed, available, &(&2 + Legs.cash(&1, commission)))

      case Pick.nearest(snapshot.chain, "put", @crash_delta) do
        %{} = put ->
          leg = Legs.open_leg("long", put)

          if affordable?(leg, available, commission),
            do: managed ++ [{:open, "long_put", [leg]}],
            else: managed

        nil ->
          managed
      end
    end
  end

  @doc """
  Ideas tonight for one underlying: manage its open calls, then buy each of
  tonight's dip-buy call ideas on it that the book has never held, while the
  book has fewer than 5 open (`open_elsewhere` counts the other
  underlyings'), the premium is at most US$2,000 and the cash covers it.
  An idea is quoted from the same snapshot it was scanned on.
  """
  @spec plan_ideas([map()], [map()], map(), float(), float(), non_neg_integer(), MapSet.t()) ::
          [tuple()]
  def plan_ideas(trades, ideas, snapshot, available, commission, open_elsewhere, held) do
    managed = Enum.map(trades, &manage("ideas", &1, snapshot.quotes, snapshot))
    still_open = Enum.count(managed, &match?({:hold, _}, &1))
    available = Enum.reduce(managed, available, &(&2 + Legs.cash(&1, commission)))

    {buys, _open, _cash} =
      ideas
      |> Enum.filter(&(&1.list == "dip_buy" and &1.kind == "call"))
      |> Enum.reject(&MapSet.member?(held, &1.contract_id))
      |> Enum.reduce({[], open_elsewhere + still_open, available}, fn idea, {buys, open, cash} ->
        quote = Map.get(snapshot.quotes, idea.contract_id)
        leg = quote && Legs.open_leg("long", Map.merge(quote, Map.take(idea, [:contract_id])))

        if open < @max_open and Pick.fillable?(quote) and
             leg.open_price * Pick.multiplier() <= @max_premium and
             affordable?(leg, cash, commission) do
          {buys ++ [{:open, "long_call", [leg]}], open + 1,
           cash + Legs.open_cash([leg], commission)}
        else
          {buys, open, cash}
        end
      end)

    managed ++ buys
  end

  defp affordable?(leg, available, commission),
    do: -Legs.open_cash([leg], commission) <= available
end
