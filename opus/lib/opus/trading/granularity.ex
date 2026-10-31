defmodule Opus.Trading.Granularity do
  @moduledoc """
  Utility module for working with granularity strings. Central source of truth for
  valid granularities and related helper functions.
  """
  @all ~w[D H4 H1 M15 M5 M1]

  defguard is_valid(g) when g in @all

  def all, do: @all
  def valid?(g), do: g in @all
end
