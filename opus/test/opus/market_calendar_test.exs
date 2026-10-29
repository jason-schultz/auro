defmodule Opus.MarketCalendarTest do
  use ExUnit.Case, async: true

  alias Opus.MarketCalendar

  test "weekdays trade, weekends and holidays don't" do
    assert MarketCalendar.trading_day?(~D[2026-10-28])
    refute MarketCalendar.trading_day?(~D[2026-10-31])
    refute MarketCalendar.trading_day?(~D[2026-11-01])
    # Thanksgiving; the day after is an early close but still trades.
    refute MarketCalendar.trading_day?(~D[2026-11-26])
    assert MarketCalendar.trading_day?(~D[2026-11-27])
  end

  test "holidays on a weekend close the observed weekday" do
    # Independence Day 2026 is a Saturday; Juneteenth and Christmas 2027 too.
    refute MarketCalendar.trading_day?(~D[2026-07-03])
    refute MarketCalendar.trading_day?(~D[2027-06-18])
    refute MarketCalendar.trading_day?(~D[2027-12-24])
    # Independence Day 2027 is a Sunday.
    refute MarketCalendar.trading_day?(~D[2027-07-05])
    refute MarketCalendar.trading_day?(~D[2027-03-26])
  end

  test "a year past the calendar raises instead of guessing" do
    assert_raise ArgumentError, ~r/no NYSE holidays for 2028/, fn ->
      MarketCalendar.trading_day?(~D[2028-01-03])
    end
  end
end
