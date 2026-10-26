defmodule Opus.Options.Paper.Wheel do
  @moduledoc """
  The wheel's rules (research/options_paper_engine.md) as pure functions
  over one underlying's open positions and one night's chain snapshot:

    1. With nothing open, sell the put 30–45 days out whose delta is
       nearest −0.25, if the cash to buy the shares is free.
    2. Each night buy a short leg back once half its premium is captured,
       or at 21 days to expiry unless it is in the money then, in which
       case it is held to expiry.
    3. At expiry an in-the-money put is assigned (100 shares at the strike)
       and an in-the-money call is called away; otherwise it expires.
    4. Holding shares, sell the call 30–45 days out whose delta is nearest
       0.30 and whose strike is at or above the shares' cost.

  Fills are pessimistic: sell at the bid, buy at the ask, and no fill at
  all without a bid or with a spread wider than 10% of the mid.
  """

  alias Opus.Options.Paper.Pick

  @put_delta -0.25
  @call_delta 0.30
  @take_profit 0.5
  @manage_dte 21
  @multiplier 100

  @type leg :: %{
          kind: String.t(),
          strike: float(),
          expiration: Date.t(),
          open_price: float(),
          quantity: pos_integer(),
          contract_id: integer()
        }
  @type lot :: %{quantity: pos_integer(), open_price: float()}
  @type snapshot :: %{
          as_of: Date.t(),
          spot: float(),
          quotes: %{integer() => map()},
          chain: [map()],
          expiry_spots: %{Date.t() => float()}
        }
  @type action ::
          {:hold, leg()}
          | {:close, leg(), float()}
          | {:expire, leg()}
          | {:assign, leg()}
          | {:call_away, leg()}
          | {:open, map()}

  def multiplier, do: @multiplier

  defdelegate fillable?(quote), to: Pick
  defdelegate mid(quote), to: Pick

  @doc """
  The contract to sell from a chain (rows with `kind`, `strike`, `dte`,
  `delta`, `bid`, `ask`): the right kind, 30–45 days out, fillable, delta
  nearest the target, and for a call a strike at or above `floor`. Ties go
  to the later expiry.
  """
  @spec pick([map()], String.t(), float()) :: map() | nil
  def pick(chain, "put", _floor), do: Pick.nearest(chain, "put", @put_delta)

  def pick(chain, "call", floor),
    do: Pick.nearest(chain, "call", @call_delta, &(&1.strike >= floor))

  @doc "What to do with one open short leg tonight, given its quote (or nil)."
  @spec manage(leg(), map() | nil, snapshot()) :: action()
  def manage(%{expiration: expiration} = leg, quote, %{as_of: as_of} = snapshot) do
    if Date.compare(as_of, expiration) == :lt do
      manage_open(leg, quote, snapshot.spot, Date.diff(expiration, as_of))
    else
      settle(leg, Map.get(snapshot.expiry_spots, expiration, snapshot.spot))
    end
  end

  defp manage_open(leg, quote, spot, dte) do
    cond do
      not fillable?(quote) -> {:hold, leg}
      quote.ask <= leg.open_price * (1 - @take_profit) -> {:close, leg, quote.ask}
      dte > @manage_dte -> {:hold, leg}
      in_the_money?(leg, spot) -> {:hold, leg}
      true -> {:close, leg, quote.ask}
    end
  end

  @doc "Settle a leg at expiry against the underlying's closing price."
  @spec settle(leg(), float()) :: action()
  def settle(leg, spot) do
    case {leg.kind, in_the_money?(leg, spot)} do
      {"put", true} -> {:assign, leg}
      {"call", true} -> {:call_away, leg}
      {_kind, false} -> {:expire, leg}
    end
  end

  @doc "The ask at or below which a short leg is bought back: half its premium kept."
  @spec take_profit_price(map()) :: float()
  def take_profit_price(%{open_price: open}), do: open * (1 - @take_profit)

  @doc "The day a short leg reaches 21 days to expiry: closed then unless in the money."
  @spec manage_on(map()) :: Date.t()
  def manage_on(%{expiration: expiration}), do: Date.add(expiration, -@manage_dte)

  @spec in_the_money?(leg(), float()) :: boolean()
  def in_the_money?(%{kind: "put", strike: strike}, spot), do: spot < strike
  def in_the_money?(%{kind: "call", strike: strike}, spot), do: spot > strike

  @doc """
  Tonight's actions for one underlying: manage each open leg, then, once
  nothing is left open, sell a call against held shares or a cash-secured
  put. `available` is the book's cash not already reserved against open
  puts; the actions taken tonight are counted before a new put is checked
  against it.
  """
  @spec plan(%{legs: [leg()], shares: lot() | nil}, snapshot(), float(), float()) :: [action()]
  def plan(%{legs: legs, shares: shares}, snapshot, available, commission) do
    managed = Enum.map(legs, &manage(&1, Map.get(snapshot.quotes, &1.contract_id), snapshot))
    available = Enum.reduce(managed, available, &(&2 + freed(&1, commission)))
    shares = Enum.reduce(managed, shares, &shares_after/2)

    if Enum.any?(managed, &match?({:hold, _}, &1)),
      do: managed,
      else: managed ++ open(shares, snapshot.chain, available)
  end

  defp open(nil, chain, available) do
    case pick(chain, "put", 0.0) do
      %{strike: strike} = put when strike * @multiplier <= available -> [{:open, put}]
      _ -> []
    end
  end

  defp open(%{open_price: cost}, chain, _available) do
    case pick(chain, "call", cost) do
      nil -> []
      call -> [{:open, call}]
    end
  end

  defp shares_after({:assign, leg}, _shares),
    do: %{quantity: leg.quantity * @multiplier, open_price: leg.strike}

  defp shares_after({:call_away, _leg}, _shares), do: nil
  defp shares_after(_action, shares), do: shares

  @doc """
  The signed change to the book's cash from an action, commission included:
  premium in on a sale, the buy-back out on a close, the shares' cost out on
  an assignment and their sale price in on a call-away.
  """
  @spec cash(action(), float()) :: float()
  def cash({:open, contract}, commission), do: contract.bid * @multiplier - commission

  def cash({:close, leg, price}, commission),
    do: -(price * @multiplier + commission) * leg.quantity

  def cash({:assign, leg}, _commission), do: -leg.strike * @multiplier * leg.quantity
  def cash({:call_away, leg}, _commission), do: leg.strike * @multiplier * leg.quantity
  def cash(_action, _commission), do: 0.0

  # Cash an action frees for a new put: its cash change plus any put
  # collateral it releases.
  defp freed(action, commission), do: cash(action, commission) + released(action)

  defp released({tag, %{kind: "put"} = leg}) when tag in [:expire, :assign],
    do: leg.strike * @multiplier * leg.quantity

  defp released({:close, %{kind: "put"} = leg, _price}),
    do: leg.strike * @multiplier * leg.quantity

  defp released(_action), do: 0.0
end
