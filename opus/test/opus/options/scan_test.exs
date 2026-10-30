defmodule Opus.Options.ScanTest do
  use Opus.DataCase, async: false

  alias Opus.Options.Scan

  @etf %{symbol: "IWM", instrument_id: 1, asset_class: "etf"}
  @single %{symbol: "NVDA", instrument_id: 2, asset_class: "equity"}
  @today ~D[2026-10-24]

  defp candidate(kind, strike, dte, attrs \\ %{}) do
    Map.merge(
      %{
        contract_id: :erlang.phash2({kind, strike, dte}),
        symbol: "IWM",
        kind: kind,
        strike: strike,
        expiration: Date.add(@today, dte),
        dte: dte,
        bid: 2.0,
        ask: 2.2,
        volatility: 20.0,
        delta: if(kind == "call", do: 0.4, else: -0.4),
        open_interest: 800,
        spot: 230.0
      },
      attrs
    )
  end

  # A stand-in for the engine: breakeven at strike plus premium, a 7%
  # expected move, and a chance of profit that falls with the strike.
  defp model(%{kind: "call", strike: strike, ask: ask, spot: spot}),
    do: %{
      "breakeven" => strike + ask,
      "expected_move" => spot * 0.07,
      "probability_profit" => max(0.0, 0.6 - (strike - spot) / spot)
    }

  defp model(%{kind: "put", strike: strike, ask: ask, spot: spot}),
    do: %{
      "breakeven" => strike - ask,
      "expected_move" => spot * 0.07,
      "probability_profit" => 0.4
    }

  # The last session before @today (a Saturday): Friday the 23rd.
  @close ~D[2026-10-23]

  defp ideas!(underlying, indicators, candidates, close_on \\ @close, scenario \\ &model/1) do
    {:ok, ideas} = Scan.ideas_for(underlying, indicators, close_on, candidates, @today, scenario)
    ideas
  end

  test "a dip-buy setup lists tradeable calls ranked, on the previous session's close" do
    indicators = %{"rsi" => 6.2, "ma_deviation_pct" => 3.1, "realized_vol_pct" => 24.0}

    candidates = [
      candidate("call", 230.0, 45),
      candidate("call", 240.0, 45, %{delta: 0.35}),
      # A lottery ticket, a deep in-the-money call, a wide spread, an empty
      # quote and nobody holding it: none of them listed.
      candidate("call", 260.0, 45, %{delta: 0.08, ask: 0.3, bid: 0.25}),
      candidate("call", 200.0, 45, %{delta: 0.85}),
      candidate("call", 235.0, 45, %{bid: 1.5, ask: 2.5}),
      candidate("call", 230.0, 45, %{bid: 0.0, ask: 0.0, strike: 300.0}),
      candidate("call", 245.0, 45, %{open_interest: 0}),
      candidate("put", 230.0, 45)
    ]

    dip = ideas!(@etf, indicators, candidates) |> Enum.filter(&(&1.list == "dip_buy"))

    assert Enum.map(dip, & &1.strike) == [230.0, 240.0]
    assert Enum.all?(dip, &(&1.kind == "call" and &1.setup =~ "RSI(2) 6.2 on the Oct 23 close"))
    assert hd(dip).breakeven_move_pct > 0 and hd(dip).expected_move_pct == 0.07
    assert hd(dip).iv_rv == 20.0 / 24.0

    assert dip
           |> Enum.map(& &1.score)
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> a >= b end)

    # An older close is stale: no dip-buy ideas from it.
    stale = ideas!(@etf, indicators, candidates, ~D[2026-10-22])
    refute Enum.any?(stale, &(&1.list == "dip_buy"))
    refute Enum.any?(ideas!(@etf, indicators, candidates, nil), &(&1.list == "dip_buy"))
  end

  test "cheap-vol lists the at-the-money pair only when implied is below realized" do
    indicators = %{"rsi" => 55.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}
    candidates = [candidate("call", 230.0, 45), candidate("put", 230.0, 45, %{volatility: 30.0})]

    cheap = ideas!(@etf, indicators, candidates)
    assert [%{list: "cheap_vol", kind: "call", strike: 230.0} = call] = cheap
    assert call.setup == "implied 20.0% vs realized 24.0% (20 sessions to the Oct 23 close)"
    assert call.iv_rv < 1.0

    # Nothing cheap today: no ideas at all.
    pricey = %{indicators | "realized_vol_pct" => 15.0}
    assert ideas!(@etf, pricey, candidates) == []
  end

  test "no setup means no dip-buy ideas; single names never get them; cheap-vol picks the expiry nearest 45 days" do
    calm = %{"rsi" => 55.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}
    oversold = %{"rsi" => 4.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}
    below_average = %{"rsi" => 4.0, "ma_deviation_pct" => -2.0, "realized_vol_pct" => 24.0}

    candidates = [
      candidate("call", 230.0, 32),
      candidate("put", 230.0, 32),
      candidate("call", 231.0, 46)
    ]

    refute Scan.dip_buy_setup?(@etf, calm)
    refute Scan.dip_buy_setup?(@etf, below_average)
    refute Scan.dip_buy_setup?(@single, oversold)
    assert Scan.dip_buy_setup?(@etf, oversold)

    ideas = ideas!(@single, oversold, candidates)
    assert Enum.map(ideas, & &1.list) == ["cheap_vol"]
    assert [%{dte: 46, strike: 231.0, kind: "call"}] = ideas
  end

  test "missing or zero volatility is no cheap-vol idea; a declining model drops the contract" do
    indicators = %{"rsi" => 4.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => nil}
    candidates = [candidate("call", 230.0, 45, %{volatility: nil})]

    assert [dip] = ideas!(@etf, indicators, candidates)
    assert dip.list == "dip_buy" and dip.iv_rv == nil and dip.rv_pct == nil

    zero = [candidate("call", 230.0, 45, %{volatility: 0.0})]

    assert [%{list: "dip_buy", iv_pct: nil}] =
             ideas!(@etf, %{indicators | "realized_vol_pct" => 24.0}, zero)

    assert ideas!(@etf, indicators, candidates, @close, fn _ -> nil end) == []
  end

  test "an engine error fails the underlying instead of dropping its ideas" do
    indicators = %{"rsi" => 4.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}

    assert {:error, "option model: " <> _} =
             Scan.ideas_for(
               @etf,
               indicators,
               @close,
               [candidate("call", 230.0, 45)],
               @today,
               fn _ ->
                 {:error, %{reason: :econnrefused}}
               end
             )
  end

  test "fresh_close? is the last session before the scan date" do
    assert Scan.fresh_close?(~D[2026-10-23], ~D[2026-10-26])
    refute Scan.fresh_close?(~D[2026-10-22], ~D[2026-10-26])
    # Thanksgiving: Friday's previous session is Wednesday.
    assert Scan.fresh_close?(~D[2026-11-25], ~D[2026-11-27])
    refute Scan.fresh_close?(nil, ~D[2026-10-26])
  end

  test "run/1 with no chains records nothing" do
    assert {:ok, 0} = Scan.run(@today)
  end

  # A chain quote for `symbol` captured at `captured_at` (UTC).
  defp chain!(symbol, captured_at) do
    {:ok, instrument} = Opus.Instruments.add(symbol, "etf")

    {1, [%{id: contract_id}]} =
      Repo.insert_all(
        "option_contracts",
        [
          %{
            ticker: "#{symbol}C",
            underlying: symbol,
            contract_type: "call",
            expiration_date: Date.add(@today, 45),
            strike: 230.0,
            first_seen_at: captured_at,
            last_seen_at: captured_at,
            underlying_instrument_id: instrument.id
          }
        ],
        returning: [:id]
      )

    Repo.insert_all("option_quotes", [
      %{
        ticker: "#{symbol}C",
        captured_at: captured_at,
        source: "questrade",
        spot: 230.0,
        bid: 2.0,
        ask: 2.1,
        contract_id: contract_id
      }
    ])

    {instrument, contract_id}
  end

  # config/test.exs points the Auro client at a closed port: every scanned
  # underlying errors on its indicators.
  @tag :capture_log
  test "run/1 keeps an errored underlying's ideas and reports it; a stale chain is skipped" do
    # 14:00 UTC is 10:00 New York on the 24th; the 23rd's chain is stale.
    {iwm, contract_id} = chain!("IWM", ~N[2026-10-24 14:00:00])
    chain!("QQQ", ~N[2026-10-23 14:00:00])

    kept =
      Repo.insert!(%Opus.Options.Idea{
        scanned_on: @today,
        list: "dip_buy",
        underlying_instrument_id: iwm.id,
        contract_id: contract_id,
        kind: "call",
        strike: 230.0,
        expiration: Date.add(@today, 45),
        dte: 45,
        spot: 230.0,
        status: "dismissed",
        setup: "earlier run"
      })

    assert {:error, words} = Scan.run(@today)
    assert words =~ "No new ideas for IWM"
    refute words =~ "QQQ"
    assert [%{id: id, status: "dismissed"}] = Repo.all(Opus.Options.Idea)
    assert id == kept.id
  end
end
