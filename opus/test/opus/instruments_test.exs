defmodule Opus.InstrumentsTest do
  # Not async: it adds instruments, whose unique keys other files' tests
  # share; two adding the same ones in parallel can deadlock.
  use Opus.DataCase, async: false

  alias Opus.Instruments

  describe "add/2 from a vendor spelling" do
    test "a .TO name is a TSX listing in CAD known to Questrade" do
      assert {:ok, ry} = Instruments.add("ry.to", "equity")
      assert {ry.symbol, ry.exchange, ry.currency} == {"RY", "TSX", "CAD"}
      assert ry.questrade_symbol == "RY.TO"
      assert ry.massive_ticker == nil
      assert ry.oanda_symbol == nil
    end

    test ".VN and .CN are the venture and CSE exchanges" do
      assert {:ok, %{exchange: "TSXV"}} = Instruments.add("DMGI.VN", "equity")
      assert {:ok, %{exchange: "CNSX"}} = Instruments.add("HODL.CN", "etf")
    end

    test "an underscore name is an OANDA CFD quoted in its second leg" do
      assert {:ok, eur} = Instruments.add("EUR_USD", "fx_major")
      assert {eur.exchange, eur.currency, eur.oanda_symbol} == {"OANDA", "USD", "EUR_USD"}
      assert eur.questrade_symbol == nil
    end

    test "a bare ticker is a US listing known to Questrade and Massive" do
      assert {:ok, spy} = Instruments.add("spy", "etf")
      assert {spy.exchange, spy.currency} == {"US", "USD"}
      assert {spy.questrade_symbol, spy.massive_ticker} == {"SPY", "SPY"}
    end

    test "the same listing twice is refused, and so is an unknown class" do
      assert {:ok, _} = Instruments.add("SPY", "etf")
      assert {:error, changeset} = Instruments.add("SPY", "etf")
      assert errors_on(changeset) != %{}
      assert {:error, changeset} = Instruments.add("QQQ", "crypto")
      assert %{asset_class: [_]} = errors_on(changeset)
    end
  end

  describe "feed_symbols/1" do
    test "returns the vendor spelling of active listings flagged for the feed, in order" do
      {:ok, xiu} = Instruments.add("XIU.TO", "etf")
      {:ok, spy} = Instruments.add("SPY", "etf")
      {:ok, aapl} = Instruments.add("AAPL", "equity")
      {:ok, _eur} = Instruments.add("EUR_USD", "fx_major")

      {:ok, _} = Instruments.toggle(xiu, :feed_questrade_bars)
      {:ok, spy} = Instruments.toggle(spy, :feed_questrade_bars)
      {:ok, _} = Instruments.toggle(spy, :feed_massive_daily)
      {:ok, aapl} = Instruments.toggle(aapl, :feed_options_chain)

      assert Instruments.feed_symbols(:questrade_bars) == ["XIU.TO", "SPY"]
      assert Instruments.feed_symbols(:massive_daily) == ["SPY"]
      assert Instruments.feed_symbols(:options_chain) == ["AAPL"]

      {:ok, _} = Instruments.toggle(aapl, :active)
      assert Instruments.feed_symbols(:options_chain) == []
    end
  end

  describe "feed_symbols/1 with Wealthsimple holdings" do
    test "a held listing is fed like a flagged one, daily too unless Massive covers it" do
      {:ok, flt} = Instruments.add("FLT.TO", "equity")
      {:ok, spy} = Instruments.add("SPY", "etf")
      {:ok, _} = Instruments.add("XIU.TO", "etf")
      {:ok, _} = Instruments.toggle(spy, :feed_massive_daily)

      %{rows: [[account]]} =
        Repo.query!(
          "INSERT INTO wealthsimple_accounts (account_type) VALUES ('Non-registered') RETURNING id"
        )

      hold = fn instrument, shares ->
        Repo.query!(
          "INSERT INTO wealthsimple_positions (account_id, symbol, shares, instrument_id) " <>
            "VALUES ($1, $2, $3, $4)",
          [account, instrument.symbol, shares, instrument.id]
        )
      end

      hold.(flt, 200.0)
      hold.(spy, 1.0)

      assert Instruments.feed_symbols(:questrade_bars) == ["FLT.TO", "SPY"]
      assert Instruments.feed_symbols(:questrade_daily) == ["FLT.TO"]

      # Sold: no longer tracked.
      Repo.query!("UPDATE wealthsimple_positions SET shares = 0 WHERE instrument_id = $1", [
        flt.id
      ])

      assert Instruments.feed_symbols(:questrade_bars) == ["SPY"]
      assert Instruments.feed_symbols(:questrade_daily) == []
    end
  end

  describe "id_for/1" do
    test "finds a listing by any vendor spelling, or says so" do
      {:ok, ry} = Instruments.add("RY.TO", "equity")
      {:ok, eur} = Instruments.add("EUR_USD", "fx_major")
      {:ok, spy} = Instruments.add("SPY", "etf")

      assert Instruments.id_for("RY.TO") == {:ok, ry.id}
      assert Instruments.id_for("EUR_USD") == {:ok, eur.id}
      assert Instruments.id_for("SPY") == {:ok, spy.id}
      assert Instruments.id_for("RY") == :error
      assert Instruments.id_for(nil) == :error
    end
  end

  describe "list/1" do
    test "searches every spelling, case-insensitively" do
      {:ok, _} = Instruments.add("RY.TO", "equity")
      {:ok, _} = Instruments.add("EUR_USD", "fx_major")
      {:ok, _} = Instruments.add("BRK.B", "equity")

      assert Enum.map(Instruments.list(), & &1.symbol) == ["EUR_USD", "RY", "BRK.B"]
      assert Enum.map(Instruments.list(search: "ry"), & &1.symbol) == ["RY"]
      assert Enum.map(Instruments.list(search: "eur_"), & &1.symbol) == ["EUR_USD"]
      assert Instruments.list(search: "zzz") == []
    end
  end
end
