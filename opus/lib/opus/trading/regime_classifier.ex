defmodule Opus.Trading.RegimeClassifier do
  @moduledoc """
  Pure logic for classifying a multi-timeframe market regime and deciding
  whether a strategy should be allowed to trade in that regime.

  Two main functions:

    * `classify_mtf/3` — given per-timeframe regime data for H4/H1/M15,
      produces a composite regime classification (`:trending`, `:choppy`,
      `:uncertain`, `:unknown`) using a 2-of-3 majority vote.

    * `policy/4` — given a strategy type and composite regime, decides whether
      the strategy should be enabled and produces a human-readable reason.

  Both are pure functions: no DB access, no HTTP calls, no GenServer state.
  Easy to test, easy to reason about. The orchestrator
  `Opus.Trading.RulesEngine` polls regime data and dispatches to these
  functions; this module owns the decision logic.
  """

  @doc """
  Classify the composite MTF regime from per-timeframe regime data.

  Returns `:unknown` if any timeframe is missing regime data (fail-closed on
  missing input). Otherwise classifies by 2-of-3 majority across H4, H1, M15.
  All three timeframes get equal vote — the slow anchor (H4) does not have
  special override power. The "is this an OK environment to trade right now"
  question is answered by present-tense conditions across the trio, not by
  any single timeframe.

  ## Classification table

    * any `:unknown` input → `:unknown`
    * 2+ trending votes → `:trending`
    * 2+ choppy votes → `:choppy`
    * otherwise → `:uncertain`
  """
  def classify_mtf(h4, h1, m15) do
    h4_regime = h4[:regime] || :unknown
    h1_regime = h1[:regime] || :unknown
    m15_regime = m15[:regime] || :unknown

    if Enum.any?([h4_regime, h1_regime, m15_regime], &(&1 == :unknown)) do
      :unknown
    else
      regimes = [h4_regime, h1_regime, m15_regime]
      trending_count = Enum.count(regimes, &(&1 == :trending))
      choppy_count = Enum.count(regimes, &(&1 == :choppy))

      cond do
        trending_count >= 2 -> :trending
        choppy_count >= 2 -> :choppy
        true -> :uncertain
      end
    end
  end

  @doc "Classify a dual-frame regime: both must agree, otherwise uncertain."
  def classify_dual(context_frame, entry_frame) do
    context_regime = context_frame[:regime] || :unknown
    entry_regime = entry_frame[:regime] || :unknown

    cond do
      context_regime == :unknown or entry_regime == :unknown -> :unknown
      context_regime == :trending and entry_regime == :trending -> :trending
      context_regime == :choppy and entry_regime == :choppy -> :choppy
      true -> :uncertain
    end
  end

  @doc "Classify from labeled regime inputs (two-frame or three-frame)."
  def classify_for_inputs([{_, a}, {_, b}]), do: classify_dual(a, b)
  def classify_for_inputs([{_, a}, {_, b}, {_, c}]), do: classify_mtf(a, b, c)
  def classify_for_inputs(_), do: :unknown

  @doc """
  Decide whether a strategy is allowed to trade given the composite regime.

  Returns `{enabled :: boolean, reason :: String.t()}`.

  ## Fail-closed semantics

  Both `:uncertain` regime and any unrecognized strategy_type or regime
  default to disabled. The previous fail-open policy on `:uncertain` was
  abandoned 2026-05-22 after live data showed material losses on uncertain-
  regime trades.
  """
  def policy("trend_following", :trending, h4, h1, m15),
    do: policy_for_inputs("trend_following", :trending, [{"H4", h4}, {"H1", h1}, {"M15", m15}])

  def policy("trend_following", :choppy, h4, h1, m15),
    do: policy_for_inputs("trend_following", :choppy, [{"H4", h4}, {"H1", h1}, {"M15", m15}])

  def policy("trend_following", :uncertain, h4, h1, m15),
    do:
      policy_for_inputs(
        "trend_following",
        :uncertain,
        [{"H4", h4}, {"H1", h1}, {"M15", m15}]
      )

  def policy("mean_reversion", :choppy, h4, h1, m15),
    do: policy_for_inputs("mean_reversion", :choppy, [{"H4", h4}, {"H1", h1}, {"M15", m15}])

  def policy("mean_reversion", :trending, h4, h1, m15),
    do: policy_for_inputs("mean_reversion", :trending, [{"H4", h4}, {"H1", h1}, {"M15", m15}])

  def policy("mean_reversion", :uncertain, h4, h1, m15),
    do:
      policy_for_inputs(
        "mean_reversion",
        :uncertain,
        [{"H4", h4}, {"H1", h1}, {"M15", m15}]
      )

  # Catch-all: unknown regime, unknown strategy_type, etc.
  def policy(_strategy_type, regime, _h4, _h1, _m15),
    do: {false, "no regime data (#{inspect(regime)}) — defaulting to disabled"}

  @doc "Policy using generic labeled timeframe inputs for reason strings."
  def policy_for_inputs("trend_following", :trending, inputs),
    do: {true, "trending TF enabled — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs("trend_following", :choppy, inputs),
    do: {false, "choppy TF disabled — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs("trend_following", :uncertain, inputs),
    do: {false, "uncertain TF disabled (fail-closed) — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs("mean_reversion", :choppy, inputs),
    do: {true, "choppy MR enabled — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs("mean_reversion", :trending, inputs),
    do: {false, "trending MR disabled — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs("mean_reversion", :uncertain, inputs),
    do: {false, "uncertain MR disabled (fail-closed) — #{adx_line_for_inputs(inputs)}"}

  def policy_for_inputs(_strategy_type, regime, _inputs),
    do: {false, "no regime data (#{inspect(regime)}) — defaulting to disabled"}

  defp adx_line_for_inputs(inputs) do
    inputs
    |> Enum.map(fn {label, frame} -> "#{label}:#{format_adx(frame[:adx])}" end)
    |> Enum.join(" ")
  end

  defp format_adx(nil), do: "n/a"
  defp format_adx(adx), do: :erlang.float_to_binary(adx, decimals: 1)
end
