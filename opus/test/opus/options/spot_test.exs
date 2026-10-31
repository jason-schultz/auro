defmodule Opus.Options.SpotTest do
  use Opus.DataCase, async: false

  alias Opus.Options.Spot
  alias OpusWeb.Components.PaperParts

  test "in the session, the last trade and its time" do
    quotes = [
      %{
        "requested" => "SPY",
        "last_trade_price" => 755.10,
        "last_trade_price_tr_hrs" => 755.10,
        "last_trade_time" => "2026-10-30T15:44:58.000000-04:00"
      },
      %{"requested" => "IWM", "last_trade_price" => nil},
      %{"symbol" => "QQQ", "last_trade_price" => 692, "last_trade_time" => "garbled"}
    ]

    assert %{
             "SPY" => %{price: 755.10, at: ~U[2026-10-30 19:44:58.000000Z], kind: :now},
             "QQQ" => %{price: 692.0, at: nil, kind: :now}
           } = Spot.from_quotes(quotes)
  end

  test "after hours, the close, with the after-hours price beside it" do
    quotes = [
      %{
        "requested" => "SPY",
        "last_trade_price" => 757.12,
        "last_trade_price_tr_hrs" => 755.72,
        "last_trade_time" => "2026-10-30T19:59:58.000000-04:00"
      }
    ]

    assert %{"SPY" => %{price: 755.72, kind: :close, after_hours: 757.12} = spy} =
             Spot.from_quotes(quotes)

    assert PaperParts.spot_words(spy) == "$755.72 at the close (after hours $757.12)"
  end

  test "with Questrade not answering, the stored 16:00 bar is the close" do
    {:ok, spyt} = Opus.Instruments.add("SPYT", "etf")

    bar = fn ny_time, close ->
      at =
        ~D[2026-10-30]
        |> DateTime.new!(ny_time, "America/New_York")
        |> DateTime.shift_zone!("Etc/UTC")

      %{
        instrument: "SPYT",
        instrument_id: spyt.id,
        granularity: "M1",
        timestamp: at,
        open: close,
        high: close,
        low: close,
        close: close,
        volume: 1,
        complete: true
      }
    end

    Repo.insert_all("candles", [
      bar.(~T[15:59:00], 755.70),
      bar.(~T[16:00:00], 755.72),
      bar.(~T[19:59:00], 757.12)
    ])

    assert %{"SPYT" => %{price: 755.72, kind: :close} = close} = Spot.now(["SPYT"])
    assert PaperParts.spot_words(close) =~ "$755.72 at the close, Oct 30"
    assert Spot.now(["NONE"]) == %{}
  end
end
