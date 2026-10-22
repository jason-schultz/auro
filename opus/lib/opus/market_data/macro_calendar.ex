defmodule Opus.MarketData.MacroCalendar do
  @moduledoc """
  Scheduled macro release times (UTC) for the calendars Auro's `EventWindow`
  strategies trade around. Source files live in `priv/macro_calendar/` — one
  ISO-8601 UTC timestamp per line, converted from the official New York
  release times (federalreserve.gov, bls.gov). Update the files when agencies
  publish new schedules.
  """

  @calendars ~w(fomc cpi nfp)

  @spec calendars() :: [String.t()]
  def calendars, do: @calendars

  @spec events(String.t()) :: {:ok, [DateTime.t()]} | {:error, term()}
  def events(name) when name in @calendars do
    with {:ok, body} <- File.read(Application.app_dir(:opus, "priv/macro_calendar/#{name}.txt")) do
      parse(body)
    end
  end

  def events(name), do: {:error, {:unknown_calendar, name}}

  @doc false
  @spec parse(String.t()) :: {:ok, [DateTime.t()]} | {:error, term()}
  def parse(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case DateTime.from_iso8601(String.trim(line)) do
        {:ok, dt, 0} -> {:cont, {:ok, [dt | acc]}}
        _ -> {:halt, {:error, {:bad_calendar_line, line}}}
      end
    end)
    |> case do
      {:ok, dts} -> {:ok, Enum.sort(dts, DateTime)}
      error -> error
    end
  end
end
