defmodule Opus.Pipeline.GridSearch do
  @moduledoc """
  Coordinate descent parameter generation for the pipeline iteration loop.

  Each depth level targets exactly ONE parameter (cycling through the parameter
  list for the strategy type). Three candidates are generated per call, each
  varying that one parameter at a different magnitude. All other parameters are
  held fixed.

  The direction of adjustment (tighten vs loosen) is determined by which metric
  dominated the failure reason.
  """

  # Parameter sweep order per strategy type.
  # Depth drives the index: rem(depth - 1, length) picks the target param.
  @mr_params ~w[entry_threshold ma_period exit_threshold stop_loss]
  @tf_params ~w[slow_period fast_period stop_loss take_profit]

  @doc """
  Returns exactly 1 candidate parameter map for the next iteration.
  One parameter is changed (determined by depth); all others are held fixed.

  Returns `{:ok, [map()]}` or `{:error, :exhausted}` if no valid candidate
  can be generated (e.g. the target parameter is nil/inapplicable).
  """
  @spec candidates(String.t(), map(), String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, :exhausted}
  def candidates(strategy_type, current_params, failure_reason, depth) do
    params = normalize_keys(current_params)
    order = param_order(strategy_type)
    target = Enum.at(order, rem(depth - 1, length(order)))

    case build_candidate(target, params, failure_reason) do
      nil -> {:error, :exhausted}
      candidate -> {:ok, [candidate]}
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter ordering
  # ---------------------------------------------------------------------------

  defp param_order("mean_reversion"), do: @mr_params
  defp param_order("trend_following"), do: @tf_params
  defp param_order(_), do: []

  # ---------------------------------------------------------------------------
  # Candidate builders — one candidate per parameter, medium adjustment
  # ---------------------------------------------------------------------------

  # entry_threshold: negative float.
  # Sharpe/expectancy low → tighten (more negative).
  # Num trades low → loosen (less negative).
  defp build_candidate("entry_threshold", params, failure_reason) do
    current = Map.get(params, "entry_threshold", -0.005)
    value = if trades_too_low?(failure_reason), do: current * 0.6, else: current * 1.5
    Map.put(params, "entry_threshold", round4(value))
  end

  # ma_period: positive integer.
  defp build_candidate("ma_period", params, failure_reason) do
    current = Map.get(params, "ma_period", 20)
    value = if trades_too_low?(failure_reason), do: max(current - 8, 5), else: current + 10
    Map.put(params, "ma_period", round(value))
  end

  # exit_threshold: positive float.
  defp build_candidate("exit_threshold", params, failure_reason) do
    current = Map.get(params, "exit_threshold", 0.003)
    value = if trades_too_low?(failure_reason), do: current * 0.6, else: current * 1.5
    Map.put(params, "exit_threshold", round4(value))
  end

  # stop_loss: negative float.
  # Drawdown too high → tighten (less negative). Default → loosen slightly.
  defp build_candidate("stop_loss", params, failure_reason) do
    current = Map.get(params, "stop_loss", -0.01)
    value = if drawdown_too_high?(failure_reason), do: current * 0.6, else: current * 1.3
    Map.put(params, "stop_loss", round4(value))
  end

  # slow_period: positive integer, must stay > fast_period.
  defp build_candidate("slow_period", params, failure_reason) do
    current = Map.get(params, "slow_period", 30)
    fast = Map.get(params, "fast_period", 10)

    value =
      if trades_too_low?(failure_reason), do: max(current - 15, fast + 5), else: current + 20

    Map.put(params, "slow_period", round(value))
  end

  # fast_period: positive integer, must stay < slow_period.
  defp build_candidate("fast_period", params, _failure_reason) do
    current = Map.get(params, "fast_period", 10)
    slow = Map.get(params, "slow_period", 30)
    value = current + 5
    if value < slow - 3, do: Map.put(params, "fast_period", round(value)), else: nil
  end

  # take_profit: positive float or nil.
  defp build_candidate("take_profit", params, _failure_reason) do
    case Map.get(params, "take_profit") do
      nil -> nil
      current -> Map.put(params, "take_profit", round3(current * 1.4))
    end
  end

  defp build_candidate(_, _, _), do: nil

  # ---------------------------------------------------------------------------
  # Failure reason helpers
  # ---------------------------------------------------------------------------

  defp trades_too_low?(reason),
    do: is_binary(reason) and String.contains?(reason, "num_trades")

  defp drawdown_too_high?(reason),
    do: is_binary(reason) and String.contains?(reason, "max_drawdown")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp round4(v), do: Float.round(v * 1.0, 4)
  defp round3(v), do: Float.round(v * 1.0, 3)

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
