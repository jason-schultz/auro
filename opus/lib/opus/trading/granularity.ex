defmodule Opus.Trading.Granularity do
  @moduledoc """
  Utility module for working with granularity strings. Central source of truth for
  valid granularities and related helper functions.
  """

  def mtf, do: ~w[M15 H1 H4]
  def all, do: ~w[M1] ++ mtf()
  def valid?(g), do: g in all()
end
