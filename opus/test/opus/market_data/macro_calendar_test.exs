defmodule Opus.MarketData.MacroCalendarTest do
  use ExUnit.Case, async: true

  alias Opus.MarketData.MacroCalendar

  test "every shipped calendar parses, sorted, unique" do
    for name <- MacroCalendar.calendars() do
      assert {:ok, dts} = MacroCalendar.events(name)
      assert length(dts) > 80
      assert dts == Enum.sort(dts, DateTime)
      assert dts == Enum.uniq(dts)
    end
  end

  test "FOMC releases are 14:00 New York (18:00 or 19:00 UTC)" do
    {:ok, dts} = MacroCalendar.events("fomc")
    assert Enum.all?(dts, &(&1.hour in [18, 19] and &1.minute == 0))
  end

  test "a malformed line is an error, comments are skipped" do
    assert {:ok, [_]} = MacroCalendar.parse("# note\n2026-10-28T18:00:00Z\n")
    assert {:error, {:bad_calendar_line, "2026-10-28"}} = MacroCalendar.parse("2026-10-28\n")
  end

  test "unknown calendar" do
    assert {:error, {:unknown_calendar, "gdp"}} = MacroCalendar.events("gdp")
  end
end
