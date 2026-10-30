defmodule OpusWeb.FormatTest do
  use ExUnit.Case, async: true

  import OpusWeb.Format

  test "money groups thousands, pads cents and uses a true minus sign" do
    assert money(299_998.96) == "$299,998.96"
    assert money(0.5) == "$0.50"
    assert money(-38.0) == "−$38.00"
    assert money(1_000_000) == "$1,000,000.00"
    assert money(nil) == "—"
  end

  test "signed_money shows a plus on gains and a true minus on losses" do
    assert signed_money(84.4) == "+$84.40"
    assert signed_money(-38.0) == "−$38.00"
    assert signed_money(nil) == "—"
  end

  test "tone is green for gains, red for losses, plain at zero" do
    assert tone(12.5) == "text-success"
    assert tone(-0.1) == "text-error"
    assert tone(0) == nil
    assert tone(nil) == nil
  end

  test "date has the year, day doesn't" do
    assert date(~D[2026-10-27]) == "Oct 27, 2026"
    assert day(~U[2026-10-27 20:00:00Z]) == "Oct 27"
    assert date(nil) == "—"
  end

  test "a timestamp's date is its date where the viewer is (Edmonton); a date stays as it is" do
    assert day(~U[2026-10-28 03:00:00Z]) == "Oct 27"
    assert date(~N[2026-10-28 03:00:00]) == "Oct 27, 2026"
    assert day(~D[2026-10-28]) == "Oct 28"
  end

  test "pct renders one decimal" do
    assert pct(0.6452) == "64.5%"
    assert pct(0.0008) == "0.1%"
    assert pct(nil) == "—"
  end

  test "shares drops decimals for whole counts" do
    assert shares(200) == "200"
    assert shares(200.0) == "200"
    assert shares(12.5) == "12.5"
    assert shares(1234) == "1,234"
  end

  test "clock and stamp show the viewer's zone (Edmonton), or the one asked for" do
    assert clock(~U[2026-10-18 17:31:09Z]) == "11:31"
    assert clock(~U[2026-10-18 17:31:09Z], "America/New_York") == "13:31"
    assert stamp(~N[2026-10-18 03:05:00]) == "Oct 17 21:05"
    assert stamp(~U[2026-12-18 14:00:00Z], "America/New_York") == "Dec 18 09:00"
    assert stamp(nil) == "—"
  end

  test "zone_name labels the zone at that instant, daylight saving included" do
    assert zone_name(~U[2026-10-18 17:31:09Z]) == "MDT"
    assert zone_name(~U[2025-12-18 17:31:09Z]) == "MST"
    assert zone_name(~U[2026-10-18 17:31:09Z], "America/New_York") == "EDT"
    assert city("America/New_York") == "New York"
  end
end
