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

  test "clock is hours and minutes" do
    assert clock(~U[2026-10-18 17:31:09Z]) == "17:31"
  end
end
