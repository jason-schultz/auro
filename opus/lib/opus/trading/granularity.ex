defmodule Opus.Trading.Granularity do
  @moduledoc """
  Utility module for working with granularity strings. Central source of truth for
  valid granularities and related helper functions.
  """
  @all ~w[D H4 H1 M15 M5 M1]
  @mtf ~w[H4 H1 M15]

  defguard is_valid(g) when g in @all

  def mtf, do: @mtf
  def all, do: @all
  def valid?(g), do: g in @all

  @doc "Returns the regime frames used to gate entries for a given strategy granularity."
  def regime_frames_for_entry("M1"), do: ~w[M5 M1]
  def regime_frames_for_entry("M5"), do: ~w[M15 M5]
  def regime_frames_for_entry("M15"), do: ~w[H1 M15]
  def regime_frames_for_entry("H1"), do: ~w[H4 H1]
  def regime_frames_for_entry("H4"), do: ~w[D H4]
  def regime_frames_for_entry("D"), do: ~w[D]
  def regime_frames_for_entry(_), do: @mtf
end
