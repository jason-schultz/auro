defmodule Opus.Options.Paper.Legs do
  @moduledoc """
  Arithmetic over a trade's option legs, shared by the books that trade more
  than the wheel's single short leg. A leg is a map with `kind` (put/call),
  `side` (short/long), `strike`, `open_price` (per share) and `quantity`.

  Cash follows the fills: a short leg is sold at the bid and bought back at
  the ask, a long leg bought at the ask and sold at the bid, every contract
  traded costs the commission, and a leg still open at expiry settles at its
  intrinsic value with no commission.
  """

  alias Opus.Options.Paper.Pick

  @spec intrinsic(String.t(), float(), float()) :: float()
  def intrinsic("put", strike, spot), do: max(strike - spot, 0.0)
  def intrinsic("call", strike, spot), do: max(spot - strike, 0.0)

  @doc "+1 for a short leg (premium in), −1 for a long one."
  @spec sign(map()) :: 1 | -1
  def sign(%{side: "short"}), do: 1
  def sign(%{side: "long"}), do: -1

  @doc "Net premium per share: positive for a credit, negative for a debit."
  @spec net_premium([map()]) :: float()
  def net_premium(legs), do: Enum.sum_by(legs, &(sign(&1) * &1.open_price * &1.quantity))

  @doc "The price a leg opens at from its quote: the bid when sold, the ask when bought."
  @spec open_price(String.t(), map()) :: float()
  def open_price("short", quote), do: quote.bid
  def open_price("long", quote), do: quote.ask

  @doc "The price a leg closes at from its quote: the ask to buy back a short, the bid to sell a long."
  @spec close_price(map(), map()) :: float()
  def close_price(%{side: "short"}, quote), do: quote.ask
  def close_price(%{side: "long"}, quote), do: quote.bid

  @doc """
  A closed leg's P&L: what it opened and closed (or settled) at, less its
  commission. Nil for a leg still open.
  """
  @spec realized(map()) :: float() | nil
  def realized(%{status: status, close_price: close} = leg)
      when status != "open" and is_number(close),
      do:
        sign(leg) * (leg.open_price - close) * Pick.multiplier() * leg.quantity -
          (leg.commission || 0.0)

  def realized(_leg), do: nil

  @doc "Cash from opening legs at `open_price`, commission included."
  @spec open_cash([map()], float()) :: float()
  def open_cash(legs, commission),
    do:
      Enum.sum_by(
        legs,
        &((sign(&1) * &1.open_price * Pick.multiplier() - commission) * &1.quantity)
      )

  @doc "Cash from closing each `{leg, price}`, commission included."
  @spec close_cash([{map(), float()}], float()) :: float()
  def close_cash(fills, commission),
    do:
      Enum.sum_by(fills, fn {leg, price} ->
        (-sign(leg) * price * Pick.multiplier() - commission) * leg.quantity
      end)

  @doc """
  Where a leg expiring on `expiration` stands on the snapshot's market date:
  `{:open, days_left}` up to and including expiry day, `{:settle, close}` once
  the expiry day's closing price is in `expiry_spots`, and `:awaiting_close`
  after expiry until it is.
  """
  @spec expiry_state(Date.t(), map()) :: {:open, integer()} | {:settle, float()} | :awaiting_close
  def expiry_state(expiration, %{as_of: as_of, expiry_spots: spots}) do
    cond do
      Map.has_key?(spots, expiration) -> {:settle, Map.fetch!(spots, expiration)}
      Date.after?(as_of, expiration) -> :awaiting_close
      true -> {:open, Date.diff(expiration, as_of)}
    end
  end

  @doc "Cash from settling legs at expiry against `spot`: intrinsic value, no commission."
  @spec settle_cash([map()], float()) :: float()
  def settle_cash(legs, spot),
    do:
      Enum.sum_by(
        legs,
        &(-sign(&1) * intrinsic(&1.kind, &1.strike, spot) * Pick.multiplier() * &1.quantity)
      )

  @doc """
  The signed change to a book's cash from a trade action: `{:open, _, legs}`,
  `{:close, trade, fills}`, `{:sell_half, trade, leg, price}` or
  `{:settle, trade, spot}`; nothing for a hold.
  """
  @spec cash(tuple(), float()) :: float()
  def cash({:open, _structure, legs}, commission), do: open_cash(legs, commission)
  def cash({:close, _trade, fills}, commission), do: close_cash(fills, commission)

  def cash({:sell_half, _trade, leg, price}, commission),
    do: close_cash([{half(leg), price}], commission)

  def cash({:settle, trade, spot}, _commission), do: settle_cash(trade.legs, spot)
  def cash({:hold, _trade}, _commission), do: 0.0

  @doc "The half of a leg's contracts that `{:sell_half, …}` sells (rounded down)."
  @spec half(map()) :: map()
  def half(leg), do: %{leg | quantity: div(leg.quantity, 2)}

  @doc """
  An option row from a chain (or an idea) as a leg to open on `side`: one
  contract at the bid when sold, the ask when bought.
  """
  @spec open_leg(String.t(), map()) :: map()
  def open_leg(side, row),
    do: Map.merge(row, %{side: side, open_price: open_price(side, row), quantity: 1})

  @doc "Dollar P&L of the legs held to expiry with the underlying at `price`."
  @spec at_expiry([map()], float()) :: float()
  def at_expiry(legs, price),
    do:
      Enum.sum_by(legs, fn leg ->
        sign(leg) * (leg.open_price - intrinsic(leg.kind, leg.strike, price)) *
          Pick.multiplier() * leg.quantity
      end)

  @doc """
  What the legs can make and lose at expiry: net premium in dollars, best
  and worst case (nil when unlimited), and every break-even. The payoff is
  linear between strikes, so its value at 0 and at each strike plus its
  slope above the top strike decide all three exactly.
  """
  @spec summary([map()]) :: %{
          net: float(),
          max_profit: float() | nil,
          max_loss: float() | nil,
          breakevens: [float()]
        }
  def summary(legs) do
    kinks = [0.0 | Enum.map(legs, & &1.strike)] |> Enum.uniq() |> Enum.sort()
    values = Enum.map(kinks, &at_expiry(legs, &1))

    slope =
      legs
      |> Enum.filter(&(&1.kind == "call"))
      |> Enum.sum_by(&(-sign(&1) * Pick.multiplier() * &1.quantity))

    crossings =
      Enum.zip([kinks, tl(kinks), values, tl(values)])
      |> Enum.flat_map(fn
        {_a, b, _va, vb} when vb == 0 -> [b]
        {a, b, va, vb} when va * vb < 0 -> [a + (b - a) * va / (va - vb)]
        _ -> []
      end)

    {top, top_value} = {List.last(kinks), List.last(values)}

    above =
      if slope != 0 and top_value * slope < 0, do: [top - top_value / slope], else: []

    %{
      net: net_premium(legs) * Pick.multiplier(),
      max_profit: if(slope <= 0, do: Enum.max(values)),
      max_loss: if(slope >= 0, do: max(-Enum.min(values), 0.0)),
      breakevens: crossings ++ above
    }
  end
end
