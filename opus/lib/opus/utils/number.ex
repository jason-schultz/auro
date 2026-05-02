defmodule Opus.Utils.Number do
  def parse_float(nil, default), do: default

  def parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_float(value, _default) when is_float(value), do: value
  def parse_float(value, _default) when is_integer(value), do: value / 1
  def parse_float(_, default), do: default

  def safe_divide(_, +0.0), do: 0.0
  def safe_divide(_, -0.0), do: 0.0
  def safe_divide(_, 0), do: 0.0
  def safe_divide(a, b), do: a / b
end
