defmodule Opus.Trading.Granularity do
  @moduledoc """
  Utility module for working with granularity strings. Central source of truth for
  valid granularities and related helper functions.
  """
  @all ~w[M1 M15 H1 H4]
  @mtf ~w[M15 H1 H4]

  defguard is_valid(g) when g in @all

  def mtf, do: @mtf
  def all, do: @all
  def valid?(g), do: g in @all
end
