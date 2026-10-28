defmodule Opus.Clock do
  @moduledoc """
  Times and dates in a time zone. Everything is stored in UTC; this turns a
  UTC timestamp into local time and dates for display or calendar questions.

  The zone is an argument that defaults to the market's: New York, where the
  US market keeps its calendar (a session's date, the forex week, the
  options schedule). Any other zone (`"America/Edmonton"`) works the same
  way. The conversion itself, daylight saving included, is the time zone
  database's (`tzdata`).
  """

  @market_zone "America/New_York"

  @doc "The market's time zone, for Oban cron entries and the like."
  @spec market_zone() :: String.t()
  def market_zone, do: @market_zone

  @doc "Today's date in `zone`."
  @spec today(String.t()) :: Date.t()
  def today(zone \\ @market_zone), do: zone |> DateTime.now!() |> DateTime.to_date()

  @doc "A UTC timestamp as local time in `zone`."
  @spec local(DateTime.t() | NaiveDateTime.t(), String.t()) :: DateTime.t()
  def local(utc, zone \\ @market_zone)

  def local(%NaiveDateTime{} = utc, zone),
    do: utc |> DateTime.from_naive!("Etc/UTC") |> local(zone)

  def local(%DateTime{} = utc, zone), do: DateTime.shift_zone!(utc, zone)

  @doc "The date of a UTC timestamp in `zone`."
  @spec date(DateTime.t() | NaiveDateTime.t(), String.t()) :: Date.t()
  def date(utc, zone \\ @market_zone), do: utc |> local(zone) |> DateTime.to_date()

  @doc "Midnight starting `date` in `zone`, as UTC."
  @spec midnight(Date.t(), String.t()) :: DateTime.t()
  def midnight(date, zone \\ @market_zone),
    do: date |> DateTime.new!(~T[00:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")
end
