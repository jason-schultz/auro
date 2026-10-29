defmodule Opus.Trading.RegimeClassifierTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.RegimeClassifier

  # ---------------------------------------------------------------------------
  # classify_mtf/3 — 2-of-3 majority vote across H4/H1/M15
  # ---------------------------------------------------------------------------

  describe "classify_mtf/3 unknown handling (fail-closed on missing data)" do
    test "returns :unknown if H4 regime is missing" do
      assert RegimeClassifier.classify_mtf(%{}, regime(:trending), regime(:trending)) == :unknown
    end

    test "returns :unknown if H1 regime is missing" do
      assert RegimeClassifier.classify_mtf(regime(:trending), %{}, regime(:trending)) == :unknown
    end

    test "returns :unknown if M15 regime is missing" do
      assert RegimeClassifier.classify_mtf(regime(:trending), regime(:trending), %{}) == :unknown
    end
  end

  describe "classify_mtf/3 trending classification (2-of-3 majority)" do
    test "all three trending → :trending" do
      assert RegimeClassifier.classify_mtf(
               regime(:trending),
               regime(:trending),
               regime(:trending)
             ) ==
               :trending
    end

    test "H4+H1 trending, M15 choppy → :trending" do
      assert RegimeClassifier.classify_mtf(regime(:trending), regime(:trending), regime(:choppy)) ==
               :trending
    end

    test "H4+H1 trending, M15 uncertain → :trending" do
      assert RegimeClassifier.classify_mtf(
               regime(:trending),
               regime(:trending),
               regime(:uncertain)
             ) ==
               :trending
    end

    test "H4+M15 trending, H1 choppy → :trending (H1 outvoted)" do
      assert RegimeClassifier.classify_mtf(regime(:trending), regime(:choppy), regime(:trending)) ==
               :trending
    end
  end

  describe "classify_mtf/3 choppy classification (2-of-3 majority)" do
    test "all three choppy → :choppy" do
      assert RegimeClassifier.classify_mtf(regime(:choppy), regime(:choppy), regime(:choppy)) ==
               :choppy
    end

    test "H1+M15 choppy, H4 trending → :choppy (anchor outvoted)" do
      assert RegimeClassifier.classify_mtf(regime(:trending), regime(:choppy), regime(:choppy)) ==
               :choppy
    end

    test "user's observed XAG case — H4 uncertain, H1+M15 choppy → :choppy" do
      assert RegimeClassifier.classify_mtf(regime(:uncertain), regime(:choppy), regime(:choppy)) ==
               :choppy
    end

    test "H4+M15 choppy, H1 uncertain → :choppy" do
      assert RegimeClassifier.classify_mtf(regime(:choppy), regime(:uncertain), regime(:choppy)) ==
               :choppy
    end
  end

  describe "classify_mtf/3 uncertain classification (no clear majority)" do
    test "all three uncertain → :uncertain" do
      assert RegimeClassifier.classify_mtf(
               regime(:uncertain),
               regime(:uncertain),
               regime(:uncertain)
             ) ==
               :uncertain
    end

    test "one each of trending/choppy/uncertain → :uncertain (no majority)" do
      assert RegimeClassifier.classify_mtf(regime(:trending), regime(:choppy), regime(:uncertain)) ==
               :uncertain
    end

    test "one trending + two uncertain → :uncertain (1 vote ≠ majority)" do
      assert RegimeClassifier.classify_mtf(
               regime(:trending),
               regime(:uncertain),
               regime(:uncertain)
             ) ==
               :uncertain
    end

    test "one choppy + two uncertain → :uncertain (1 vote ≠ majority)" do
      assert RegimeClassifier.classify_mtf(
               regime(:uncertain),
               regime(:choppy),
               regime(:uncertain)
             ) ==
               :uncertain
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp regime(state), do: %{regime: state, adx: nil}
end
