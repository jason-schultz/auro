defmodule Opus.MarketCalendar do
  @moduledoc """
  The US stock market's calendar (NYSE): which dates it trades. Weekends and
  the full-day holidays below are closed; early closes (the day after
  Thanksgiving, Christmas Eve) count as trading days.

  The holidays are data, a year at a time, with the observed dates (a
  holiday on a Saturday is taken the Friday before, on a Sunday the Monday
  after, except New Year's Day on a Saturday, which isn't moved). Asking
  about a year that isn't listed raises, so the calendar can't run out
  silently: the job asking fails and shows on the dashboard. Add the next
  year from the NYSE's published list before it starts.
  """

  @holidays %{
    2026 => [
      ~D[2026-01-01],
      ~D[2026-01-19],
      ~D[2026-02-16],
      ~D[2026-04-03],
      ~D[2026-05-25],
      ~D[2026-06-19],
      ~D[2026-07-03],
      ~D[2026-09-07],
      ~D[2026-11-26],
      ~D[2026-12-25]
    ],
    2027 => [
      ~D[2027-01-01],
      ~D[2027-01-18],
      ~D[2027-02-15],
      ~D[2027-03-26],
      ~D[2027-05-31],
      ~D[2027-06-18],
      ~D[2027-07-05],
      ~D[2027-09-06],
      ~D[2027-11-25],
      ~D[2027-12-24]
    ]
  }

  @doc """
  Whether the US stock market trades on `date`. Raises for a year the
  calendar doesn't list.
  """
  @spec trading_day?(Date.t()) :: boolean()
  def trading_day?(%Date{year: year} = date) do
    holidays =
      Map.get(@holidays, year) ||
        raise ArgumentError,
              "Opus.MarketCalendar has no NYSE holidays for #{year}: " <>
                "add that year's dates to lib/opus/market_calendar.ex"

    Date.day_of_week(date) <= 5 and date not in holidays
  end

  @doc """
  The last trading day before `date`: the session whose daily bar should be
  the latest stored on `date`. Raises like `trading_day?/1` for a year the
  calendar doesn't list.
  """
  @spec previous_trading_day(Date.t()) :: Date.t()
  def previous_trading_day(%Date{} = date) do
    previous = Date.add(date, -1)
    if trading_day?(previous), do: previous, else: previous_trading_day(previous)
  end
end
