defmodule Opus.Trading.ExecutionQuality do
  @moduledoc """
  Live fills versus the fills the backtest assumed.

  Rust records, on every evaluator-driven entry and exit, the fill the backtest
  would have used for the decision bar (ask close for a long entry, bid close
  for a short entry, the reverse on exit) and that bar's spread. Comparing the
  OANDA fill against it gives slippage in basis points, signed so that positive
  always means "worse than the backtest". A strategy whose backtest edge is a
  few basis points per trade lives or dies on this number.

  Stop-loss exits are closed by OANDA, not by a bar decision, so they carry no
  expected exit price and are excluded from exit slippage.
  """

  @bp 10_000.0

  @typedoc "One live trade with the fields this module reads."
  @type trade :: %{
          required(:live_strategy_id) => String.t() | nil,
          required(:direction) => String.t(),
          required(:entry_price) => float() | nil,
          required(:exit_price) => float() | nil,
          required(:expected_entry_price) => float() | nil,
          required(:entry_spread) => float() | nil,
          required(:expected_exit_price) => float() | nil,
          required(:exit_spread) => float() | nil,
          optional(any()) => any()
        }

  @doc """
  Entry slippage in basis points of the expected price; positive = paid more
  than the backtest assumed. `nil` when either price is missing.
  """
  @spec entry_slippage_bp(trade()) :: float() | nil
  def entry_slippage_bp(%{entry_price: fill, expected_entry_price: expected} = t)
      when is_number(fill) and is_number(expected) and expected > 0 do
    sign(t.direction) * (fill - expected) / expected * @bp
  end

  def entry_slippage_bp(_), do: nil

  @doc "Exit slippage in basis points; positive = received less than the backtest assumed."
  @spec exit_slippage_bp(trade()) :: float() | nil
  def exit_slippage_bp(%{exit_price: fill, expected_exit_price: expected} = t)
      when is_number(fill) and is_number(expected) and expected > 0 do
    sign(t.direction) * (expected - fill) / expected * @bp
  end

  def exit_slippage_bp(_), do: nil

  @doc "Spread at the entry decision bar, in basis points of the expected entry price."
  @spec entry_spread_bp(trade()) :: float() | nil
  def entry_spread_bp(%{entry_spread: spread, expected_entry_price: expected})
      when is_number(spread) and is_number(expected) and expected > 0,
      do: spread / expected * @bp

  def entry_spread_bp(_), do: nil

  @doc """
  Per-strategy summary of a list of trades (any order). Each entry carries the
  trade counts behind every mean so a single fill can't masquerade as a trend.
  """
  @spec summarize([trade()]) :: [map()]
  def summarize(trades) do
    trades
    |> Enum.group_by(& &1.live_strategy_id)
    |> Enum.map(fn {strategy_id, group} ->
      entry = group |> Enum.map(&entry_slippage_bp/1) |> Enum.reject(&is_nil/1)
      exit = group |> Enum.map(&exit_slippage_bp/1) |> Enum.reject(&is_nil/1)
      spread = group |> Enum.map(&entry_spread_bp/1) |> Enum.reject(&is_nil/1)

      %{
        live_strategy_id: strategy_id,
        trades: length(group),
        entries_measured: length(entry),
        exits_measured: length(exit),
        mean_entry_slippage_bp: mean(entry),
        median_entry_slippage_bp: median(entry),
        mean_exit_slippage_bp: mean(exit),
        median_exit_slippage_bp: median(exit),
        mean_spread_bp: mean(spread),
        # What a round trip cost beyond the backtest's spread assumption.
        mean_round_trip_excess_bp: add(mean(entry), mean(exit))
      }
    end)
    |> Enum.sort_by(& &1.live_strategy_id)
  end

  defp sign("long"), do: 1.0
  defp sign("short"), do: -1.0
  defp sign(other) when is_binary(other), do: sign(String.downcase(other))

  defp mean([]), do: nil
  defp mean(xs), do: Float.round(Enum.sum(xs) / length(xs), 2)

  defp median([]), do: nil

  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    mid = div(n, 2)

    value =
      if rem(n, 2) == 1,
        do: Enum.at(sorted, mid),
        else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2

    Float.round(value, 2)
  end

  defp add(nil, _), do: nil
  defp add(_, nil), do: nil
  defp add(a, b), do: Float.round(a + b, 2)
end
