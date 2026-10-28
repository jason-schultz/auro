defmodule Opus.Options.Paper.LongOptions do
  @moduledoc """
  The books that buy options (research/options_paper_engine.md, v2), as
  pure functions over one underlying's open trades and one night's snapshot:

    * **ideas:** buy one contract of each new dip-buy call the nightly scan
      flags, at most 5 open across the book and at most US$2,000 of premium
      each; sell at double the price paid, at half of it, or at 21 days to
      expiry;
    * **crash puts:** hold one put nearest −0.10 delta; at 21 days to expiry
      sell it and buy the next month's (a roll), with no take-profit;
    * **"half at double"** (`ideas_half`, `crash_puts_half`): the same
      entries with two contracts. At double the price paid one is sold,
      which pays back what both cost; the other rides until 21 days to
      expiry or until it falls back to the price paid. Before the double,
      ideas still sell both at half, and crash puts still roll at 21 days.

  Buys are at the ask and sales at the bid; a long option still open at
  expiry settles at its intrinsic value. The premium paid is all it can
  lose, so nothing is reserved.
  """

  alias Opus.Options.Paper.{Legs, Pick}

  @manage_dte 21
  @max_open 5
  @max_premium 2_000.0
  @crash_delta -0.10
  @half_books ~w(ideas_half crash_puts_half)

  @doc "Contracts a book buys per trade: two in a half-at-double book, so one can be sold."
  @spec contracts(String.t()) :: pos_integer()
  def contracts(book) when book in @half_books, do: 2
  def contracts(_book), do: 1

  @doc """
  What to do with one open long option tonight. Besides `{:hold, trade}`,
  `{:close, trade, fills}` and `{:settle, trade, close}`, a half-at-double
  book can `{:sell_half, trade, leg, bid}`: sell half its contracts and keep
  the trade open.
  """
  @spec manage(String.t(), map(), %{integer() => map()}, map()) :: tuple()
  def manage(
        book,
        %{legs: [%{expiration: expiration} = leg]} = trade,
        quotes,
        snapshot
      ) do
    case Legs.expiry_state(expiration, snapshot) do
      {:open, dte} -> exit_rule(book, trade, leg, Map.get(quotes, leg.contract_id), dte)
      {:settle, close} -> {:settle, trade, close}
      :awaiting_close -> {:hold, trade}
    end
  end

  defp exit_rule(book, trade, leg, quote, dte) do
    cond do
      not Pick.fillable?(quote) -> {:hold, trade}
      dte <= @manage_dte -> {:close, trade, [{leg, quote.bid}]}
      true -> price_rule(book, trade, leg, quote.bid)
    end
  end

  defp price_rule(book, trade, leg, bid) do
    case double(book, trade, leg, bid) do
      {:hold, trade} -> stop(book, trade, leg, bid)
      action -> action
    end
  end

  @doc """
  The take-profit on its own, as the resting order a broker would hold:
  at double the price paid, ideas sell the call and a half-at-double book
  sells half (crash puts have none). Checked by the daily rules and on
  every intraday quote.
  """
  @spec take_profit(String.t(), map(), %{integer() => map()}) :: tuple()
  def take_profit(book, %{legs: [leg]} = trade, quotes) do
    quote = Map.get(quotes, leg.contract_id)

    if Pick.fillable?(quote),
      do: double(book, trade, leg, quote.bid),
      else: {:hold, trade}
  end

  defp double(book, trade, %{quantity: contracts} = leg, bid)
       when book in @half_books and contracts > 1 do
    if bid >= leg.open_price * 2, do: {:sell_half, trade, leg, bid}, else: {:hold, trade}
  end

  defp double("ideas", trade, leg, bid) do
    if bid >= leg.open_price * 2, do: {:close, trade, [{leg, bid}]}, else: {:hold, trade}
  end

  defp double(_book, trade, _leg, _bid), do: {:hold, trade}

  # A half-at-double book with one contract left has sold its half: the
  # rest is sold if it falls back to the price paid. Ideas (both books,
  # before any half is sold) are sold at half.
  defp stop(book, trade, %{quantity: 1} = leg, bid) when book in @half_books do
    if bid <= leg.open_price, do: {:close, trade, [{leg, bid}]}, else: {:hold, trade}
  end

  defp stop(book, trade, leg, bid) when book in ~w(ideas ideas_half) do
    if bid <= leg.open_price * 0.5, do: {:close, trade, [{leg, bid}]}, else: {:hold, trade}
  end

  defp stop(_book, trade, _leg, _bid), do: {:hold, trade}

  # A trade the night's action leaves open.
  defp still_open?({:hold, _trade}), do: true
  defp still_open?({:sell_half, _trade, _leg, _bid}), do: true
  defp still_open?(_action), do: false

  @doc """
  Crash puts tonight (`crash_puts` or `crash_puts_half`): manage the open
  put, and with none left open buy the put nearest −0.10 delta if the
  book's cash covers it.
  """
  @spec plan_crash_puts(String.t(), [map()], map(), float(), float()) :: [tuple()]
  def plan_crash_puts(book, trades, snapshot, available, commission) do
    managed = Enum.map(trades, &manage(book, &1, snapshot.quotes, snapshot))

    if Enum.any?(managed, &still_open?/1) do
      managed
    else
      available = Enum.reduce(managed, available, &(&2 + Legs.cash(&1, commission)))

      case Pick.nearest(snapshot.chain, "put", @crash_delta) do
        %{} = put ->
          leg = %{Legs.open_leg("long", put) | quantity: contracts(book)}

          if affordable?(leg, available, commission),
            do: managed ++ [{:open, "long_put", [leg]}],
            else: managed

        nil ->
          managed
      end
    end
  end

  @doc """
  Ideas tonight for one underlying (`ideas` or `ideas_half`): manage its
  open calls, then buy each of tonight's dip-buy call ideas on it that the
  book has never held, while the book has fewer than 5 open
  (`open_elsewhere` counts the other underlyings'), the premium is at most
  US$2,000 a contract and the cash covers it. An idea is quoted from the
  same snapshot it was scanned on.
  """
  @spec plan_ideas(
          String.t(),
          [map()],
          [map()],
          map(),
          float(),
          float(),
          non_neg_integer(),
          MapSet.t()
        ) :: [tuple()]
  def plan_ideas(book, trades, ideas, snapshot, available, commission, open_elsewhere, held) do
    managed = Enum.map(trades, &manage(book, &1, snapshot.quotes, snapshot))
    still_open = Enum.count(managed, &still_open?/1)
    available = Enum.reduce(managed, available, &(&2 + Legs.cash(&1, commission)))

    {buys, _open, _cash} =
      ideas
      |> Enum.filter(&(&1.list == "dip_buy" and &1.kind == "call"))
      |> Enum.reject(&MapSet.member?(held, &1.contract_id))
      |> Enum.reduce({[], open_elsewhere + still_open, available}, fn idea, {buys, open, cash} ->
        quote = Map.get(snapshot.quotes, idea.contract_id)

        leg =
          quote &&
            %{
              Legs.open_leg("long", Map.merge(quote, Map.take(idea, [:contract_id])))
              | quantity: contracts(book)
            }

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
