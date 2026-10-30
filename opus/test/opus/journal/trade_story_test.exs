defmodule Opus.Journal.TradeStoryTest do
  use ExUnit.Case, async: true

  alias Opus.Journal.TradeStory

  @params %{
    "components" => %{
      "na" => %{"type" => "NoiseArea", "params" => %{"lookback_sessions" => 14}}
    }
  }

  # The NAS100 noise-area trade of 2026-10-26, as Rust recorded it.
  defp session_close_win do
    %{
      instrument: "NAS100_USD",
      direction: "Long",
      units: "1.00",
      status: "closed",
      entry_price: 29_203.6,
      exit_price: 29_312.5,
      entry_time: ~U[2026-10-26 14:30:02Z],
      exit_time: ~U[2026-10-26 20:00:02Z],
      stop_loss_price: 28_873.125,
      pnl: 151.151,
      pnl_percent: 0.0037290,
      entry_reason: "Composite Long entry",
      exit_reason:
        ~s|CompositeExit (ports={"na": {"session_close": true, "exit_short": false, "exit_long": false, "long": false, "short": false}})|,
      indicators_at_entry: %{"components" => ["na"]},
      mfe_pct: 0.0076292,
      mae_pct: 0.0017018,
      sizing_metadata: %{
        "risk_pct" => 0.01,
        "raw_units" => 1.891,
        "clamped_units" => 1.0,
        "clamps_applied" => ["policy_cap"],
        "equity_at_decision" => 86_832.19,
        "quote_to_home_rate" => 1.404885,
        "notional_pct_of_nav" => 0.4724
      },
      expected_entry_price: 29_206.6,
      entry_spread: 1.1,
      expected_exit_price: 29_302.5,
      exit_spread: 0.8
    }
  end

  test "tells a winning day trade in plain words" do
    story = TradeStory.tell(session_close_win(), %{parameters: @params})

    assert story.result == :win
    assert story.headline == "Made $151.15 (+0.37%)"

    story_text = Map.new(story.story)

    assert story_text["Opened"] =~
             "Bought 1 unit of NAS100 at 29,203.6 on Mon Oct 26, 8:30 AM MDT"

    assert story_text["Why"] =~ "broke above its noise area"
    assert story_text["Why"] =~ "last 14 sessions"
    assert story_text["Closed"] =~ "end of the trading day"
    assert story_text["Held"] == "5h 30m."

    numbers = Map.new(story.numbers, fn {label, value, _note} -> {label, value} end)
    assert numbers["Kept"] == "49%"
    assert numbers["Best point"] =~ "+0.76%"
    assert numbers["Risked"] =~ "1.13% (≈ $4"
    assert numbers["Entry fill"] =~ "better than the backtest assumed"

    assert [giveback, cap] = story.takeaways
    assert giveback =~ "up +0.76% at its best and kept 49%"
    assert cap =~ "cut it from 1.89 units to 1 unit"
  end

  test "a stop-loss loss within its plan is not a mistake; a gap past the stop is flagged" do
    loss = %{
      session_close_win()
      | exit_reason: "StopLoss",
        exit_price: 28_873.1,
        pnl: -459.0,
        pnl_percent: -0.01131,
        mfe_pct: 0.001,
        sizing_metadata: nil,
        expected_exit_price: nil
    }

    story = TradeStory.tell(loss, %{parameters: @params})
    assert story.headline == "Lost $459.00 (−1.13%)"
    assert Map.new(story.story)["Closed"] =~ "hit its stop-loss at 28,873.1"
    assert [planned] = story.takeaways
    assert planned =~ "the loss this strategy accepts on purpose"

    gapped = %{loss | exit_price: 28_500.0, pnl: -950.0, pnl_percent: -0.0241}
    assert [jumped] = TradeStory.tell(gapped, %{parameters: @params}).takeaways
    assert jumped =~ "jumped past the stop"
  end

  test "a trade with nothing to note says so" do
    clean = %{session_close_win() | mfe_pct: 0.004, sizing_metadata: nil}
    assert [line] = TradeStory.tell(clean, %{parameters: @params}).takeaways
    assert line =~ "Nothing stands out"
  end

  test "exit labels for tables" do
    trade = session_close_win()
    assert TradeStory.exit_label(trade) == "End of the trading day"

    faded =
      ~s|CompositeExit (ports={"na": {"exit_long": true, "exit_short": true, "session_close": false}})|

    assert TradeStory.exit_label(%{trade | exit_reason: faded}) == "The move faded"

    reverted = ~s|CompositeExit (ports={"mr": {"exit_short": true, "exit_long": false}})|

    assert TradeStory.exit_label(%{trade | exit_reason: reverted, direction: "Short"}) ==
             "Back to its average"

    assert TradeStory.exit_label(%{trade | exit_reason: "TrailingStop"}) == "Trailing stop hit"

    assert TradeStory.exit_label(%{trade | exit_reason: "TrendReversal: fast_ma=1, slow_ma=2"}) ==
             "The trend turned"

    assert TradeStory.exit_label(%{trade | status: "open", exit_reason: nil}) == "Still open"
  end
end
