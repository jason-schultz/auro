defmodule Opus.Trading.RegimeClassifier do
  @moduledoc """
  Pure logic for reading a multi-timeframe market regime from per-frame ADX
  classifications (`Opus.Trading.RegimeDetector`): `:trending`, `:choppy`,
  `:uncertain` or `:unknown`.

  A readout for screens only. Strategies decide whether they trade through
  their own blocks; nothing switches a strategy on or off by regime.
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
end
