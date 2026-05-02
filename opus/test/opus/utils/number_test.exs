defmodule Opus.Utils.NumberTest do
  use ExUnit.Case, async: true

  alias Opus.Utils.Number

  describe "parse_float/2" do
    test "parses string float" do
      assert Number.parse_float("110.611", 0.0) == 110.611
    end

    test "parses string with trailing characters" do
      # Float.parse returns {f, rest} — we keep the float
      assert Number.parse_float("110.611abc", 0.0) == 110.611
    end

    test "returns default for unparseable string" do
      assert Number.parse_float("not a number", 0.0) == 0.0
    end

    test "returns default for nil" do
      assert Number.parse_float(nil, 0.0) == 0.0
    end

    test "passes through float unchanged" do
      assert Number.parse_float(110.611, 0.0) == 110.611
    end

    test "converts integer to float" do
      assert Number.parse_float(110, 0.0) == 110.0
    end

    test "returns default for unexpected type" do
      assert Number.parse_float(%{}, 99.9) == 99.9
      assert Number.parse_float([], 99.9) == 99.9
    end
  end

  describe "safe_divide/2" do
    test "divides normally" do
      assert Number.safe_divide(10.0, 2.0) == 5.0
    end

    test "returns 0.0 for positive zero divisor" do
      assert Number.safe_divide(10.0, +0.0) == 0.0
    end

    test "returns 0.0 for negative zero divisor" do
      assert Number.safe_divide(10.0, -0.0) == 0.0
    end

    test "returns 0.0 for integer zero divisor" do
      assert Number.safe_divide(10.0, 0) == 0.0
    end

    test "handles negative numerator" do
      assert Number.safe_divide(-10.0, 2.0) == -5.0
    end
  end
end
