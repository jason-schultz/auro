defmodule Opus.Options.Spot do
  @moduledoc """
  The underlyings' prices now, from Questrade through the live engine
  (`GET /api/questrade/quotes`), for the options pages to show beside the
  price the paper books were last valued at (their 15-minute option
  snapshots, the last at 15:45 New York).
  """

  alias Opus.Auro.Client

  @type now :: %{String.t() => %{price: float(), at: DateTime.t() | nil}}

  @doc "Each of `symbols`' last trade and when it was; `%{}` when the engine can't say."
  @spec now([String.t()]) :: now()
  def now([]), do: %{}

  def now(symbols) do
    case Client.get_questrade_quotes(symbols) do
      {:ok, %{"quotes" => quotes}} -> from_quotes(quotes)
      _ -> %{}
    end
  end

  @doc "The quotes endpoint's rows as `now/1` gives them."
  @spec from_quotes([map()]) :: now()
  def from_quotes(quotes) do
    for %{"last_trade_price" => price} = q <- quotes, is_number(price) and price > 0, into: %{} do
      {q["requested"] || q["symbol"], %{price: price / 1, at: at(q["last_trade_time"])}}
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
