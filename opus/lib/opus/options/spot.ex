defmodule Opus.Options.Spot do
  @moduledoc """
  The underlyings' latest prices, for the options pages to show beside the
  price the paper books were last valued at (their 15-minute option
  snapshots, the last at 15:45 New York).

    * In the session: Questrade's last trade, through the live engine
      (`GET /api/questrade/quotes`).
    * Outside it: the day's close (Questrade's last regular-hours trade),
      with the after-hours price beside it, not a late after-hours trade.
    * Questrade not answering: the last regular-session price in the
      stored one-minute bars (the 16:00 bar is the closing print).
  """

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.{Clock, Repo}

  @type price :: %{
          price: float(),
          at: DateTime.t() | nil,
          kind: :now | :close,
          after_hours: float() | nil
        }
  @type now :: %{String.t() => price()}

  @open ~T[09:30:00]
  @close ~T[16:00:00]

  @doc "The latest price of each of `symbols` that has one."
  @spec now([String.t()]) :: now()
  def now([]), do: %{}

  def now(symbols) do
    live =
      case Client.get_questrade_quotes(symbols) do
        {:ok, %{"quotes" => quotes}} -> from_quotes(quotes)
        _ -> %{}
      end

    symbols
    |> Enum.reject(&Map.has_key?(live, &1))
    |> Enum.reduce(live, fn symbol, acc ->
      case stored_close(symbol) do
        nil -> acc
        price -> Map.put(acc, symbol, price)
      end
    end)
  end

  @doc "The quotes endpoint's rows as `now/1` gives them."
  @spec from_quotes([map()]) :: now()
  def from_quotes(quotes) do
    for %{"last_trade_price" => last} = q <- quotes, is_number(last) and last > 0, into: %{} do
      {q["requested"] || q["symbol"],
       price(last, q["last_trade_price_tr_hrs"], at(q["last_trade_time"]))}
    end
  end

  # A last trade outside the session is after hours: the regular-hours
  # last trade is the close.
  defp price(last, regular, at) when is_number(regular) and regular > 0 do
    if in_session?(at),
      do: %{price: last / 1, at: at, kind: :now, after_hours: nil},
      else: %{price: regular / 1, at: nil, kind: :close, after_hours: last / 1}
  end

  defp price(last, _regular, at), do: %{price: last / 1, at: at, kind: :now, after_hours: nil}

  defp in_session?(nil), do: true

  defp in_session?(at) do
    time = at |> DateTime.shift_zone!(Clock.market_zone()) |> DateTime.to_time()
    Time.compare(time, @open) != :lt and Time.compare(time, @close) == :lt
  end

  @doc "The last regular-session one-minute close stored for `symbol`, or nil."
  @spec stored_close(String.t()) :: price() | nil
  def stored_close(symbol) do
    from(c in "candles",
      where:
        c.instrument == ^symbol and c.granularity == "M1" and
          fragment("(? AT TIME ZONE 'America/New_York')::time", c.timestamp) >= ^@open and
          fragment("(? AT TIME ZONE 'America/New_York')::time", c.timestamp) <= ^@close,
      order_by: [desc: c.timestamp],
      limit: 1,
      select: {c.close, type(c.timestamp, :utc_datetime)}
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      {close, at} ->
        closing? = at |> DateTime.shift_zone!(Clock.market_zone()) |> DateTime.to_time() == @close
        %{price: close / 1, at: at, kind: if(closing?, do: :close, else: :now), after_hours: nil}
    end
  end

  defp at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp at(_), do: nil
end
