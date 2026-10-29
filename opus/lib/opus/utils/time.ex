defmodule Opus.Utils.Time do
  @moduledoc "Parsing the ISO 8601 times the engine and OANDA send."

  @doc """
  An ISO 8601 / RFC 3339 time as a UTC `DateTime` (sub-microsecond digits,
  as OANDA sends, are cut to microseconds). Raises on anything else: for
  payloads where a time is required.
  """
  @spec parse_iso8601!(String.t()) :: DateTime.t()
  def parse_iso8601!(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  @doc "Like `parse_iso8601!/1`, but nil for nil or a value that isn't a time."
  @spec parse_iso8601(term()) :: DateTime.t() | nil
  def parse_iso8601(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  def parse_iso8601(_text), do: nil
end
