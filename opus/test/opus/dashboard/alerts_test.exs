defmodule Opus.Dashboard.AlertsTest do
  use ExUnit.Case, async: true

  alias Opus.Dashboard.Alerts

  # Tuesday 2026-10-27 15:00 UTC: the forex market is open.
  @now ~U[2026-10-27 15:00:00Z]

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        now: @now,
        today: DateTime.to_date(@now),
        engine: :up,
        candle_age: 30,
        suspensions: [],
        failed_jobs: [],
        offline_brokers: [],
        exposure: %{exposure: 1.0, realized_vol: 0.09},
        paper: [],
        paper_events: [],
        live_closes: [],
        ideas: nil
      },
      overrides
    )
  end

  defp wheel_put(overrides) do
    Map.merge(
      %{
        book: "wheel",
        symbol: "SPY",
        label: "SPY $734.00 put (wheel)",
        link: "/options?view=paper&book=wheel&trade=SPY",
        spot: 761.0,
        expiration: ~D[2026-11-30],
        manage_on: ~D[2026-11-09],
        shorts: [%{kind: "put", strike: 734.0}],
        longs: [],
        max_loss: nil,
        take_profit: %{close_cost: 6.5, target: 3.25}
      },
      overrides
    )
  end

  defp titles(alerts), do: Enum.map(alerts, & &1.title)

  test "a calm day has nothing to act on" do
    assert Alerts.build(input()) == []
  end

  test "an unreachable engine is an act-now alert" do
    [alert] = Alerts.build(input(%{engine: {:down, "Auro is not running."}}))
    assert alert.level == :act
    assert alert.title =~ "not running"
    assert alert.what_to_do =~ "Questrade token"
  end

  test "a suspension links to the strategy's page" do
    [alert] =
      Alerts.build(input(%{suspensions: [%{id: "abc", name: "Euro dip-buy", detail: "-6%"}]}))

    assert alert.level == :act
    assert alert.link == "/strategies/abc"
    assert alert.what_to_do =~ "Reset"
  end

  test "failed jobs are grouped per worker under a plain name" do
    jobs = [
      %{worker: "Opus.MarketData.OptionsChainWorker", error: "timeout"},
      %{worker: "Opus.MarketData.OptionsChainWorker", error: "timeout"}
    ]

    [alert] = Alerts.build(input(%{failed_jobs: jobs}))
    assert alert.title == "Option chain snapshot failed (2 times)"
    assert Alerts.worker_name("Opus.Something.NewWorker") == "NewWorker"
  end

  test "stale candles only matter while the market is open" do
    assert [%{level: :act}] = Alerts.build(input(%{candle_age: 601}))
    assert Alerts.build(input(%{candle_age: 600})) == []

    saturday = ~U[2026-10-31 15:00:00Z]
    assert Alerts.build(input(%{candle_age: 5000, now: saturday})) == []
  end

  test "the forex week runs Sunday 17:00 to Friday 17:00 New York" do
    # Daylight time (UTC−4): 17:00 New York is 21:00 UTC.
    refute Alerts.forex_open?(~U[2026-10-25 20:59:00Z])
    assert Alerts.forex_open?(~U[2026-10-25 21:00:00Z])
    assert Alerts.forex_open?(~U[2026-10-23 20:59:00Z])
    refute Alerts.forex_open?(~U[2026-10-23 21:00:00Z])
    # Standard time (UTC−5): 17:00 New York is 22:00 UTC.
    assert Alerts.forex_open?(~U[2026-11-06 21:30:00Z])
    refute Alerts.forex_open?(~U[2026-11-06 22:00:00Z])
  end

  test "an offline broker links to the accounts page" do
    [alert] =
      Alerts.build(input(%{offline_brokers: [%{broker: "Questrade", error: "401"}]}))

    assert alert.title == "Questrade is offline"
    assert alert.link == "/accounts"
  end

  test "a wheel put in the money is held, and the alert says so" do
    [alert] = Alerts.build(input(%{paper: [wheel_put(%{spot: 720.0})]}))
    assert alert.level == :act
    assert alert.title =~ "in the money"
    assert alert.what_to_do =~ "100 shares are bought at $734.00"
  end

  test "a spread in the money says when the rules close it and its most loss" do
    spread =
      wheel_put(%{
        book: "put_spread",
        label: "SPY put spread 734/724",
        spot: 730.0,
        longs: [%{kind: "put", strike: 724.0}],
        max_loss: 750.0,
        take_profit: nil
      })

    [alert] = Alerts.build(input(%{paper: [spread]}))
    assert alert.what_to_do =~ "Nov 9"
    assert alert.what_to_do =~ "$750.00"
  end

  test "assignments and call-aways are act-now, other events are fyi" do
    events = [
      %{
        book: "wheel",
        symbol: "SPY",
        kind: "assign",
        cash: -73_400.0,
        on: ~D[2026-11-30],
        link: "/x"
      },
      %{book: "wheel", symbol: "IWM", kind: "open", cash: 316.9, on: ~D[2026-11-30], link: "/y"}
    ]

    [act, fyi] = Alerts.build(input(%{paper_events: events}))
    assert act.level == :act and act.title =~ "assigned 100 SPY"
    assert fyi.level == :fyi and fyi.title == "Paper wheel: IWM opened"
  end

  test "within 2% of the strike is a check" do
    assert [%{level: :check, title: title}] =
             Alerts.build(input(%{paper: [wheel_put(%{spot: 748.0})]}))

    assert title =~ "near its strike"
    assert Alerts.build(input(%{paper: [wheel_put(%{spot: 750.0})]})) == []
  end

  test "the 21-day check is flagged from 3 days out and says what the rule does" do
    due = wheel_put(%{manage_on: ~D[2026-10-30]})
    [alert] = Alerts.build(input(%{paper: [due]}))
    assert alert.title =~ "in 3 days"
    assert alert.what_to_do =~ "buys it back if SPY is above $734.00"

    assert Alerts.build(input(%{paper: [wheel_put(%{manage_on: ~D[2026-10-31]})]})) == []

    assert [%{title: t}] =
             Alerts.build(input(%{paper: [wheel_put(%{manage_on: ~D[2026-10-27]})]}))

    assert t =~ "today"
  end

  test "within 10% of take-profit is a check, for credit and long trades" do
    near = wheel_put(%{take_profit: %{close_cost: 3.5, target: 3.25}})
    assert [%{title: t}] = Alerts.build(input(%{paper: [near]}))
    assert t =~ "take-profit"

    far = wheel_put(%{take_profit: %{close_cost: 3.6, target: 3.25}})
    assert Alerts.build(input(%{paper: [far]})) == []

    call =
      wheel_put(%{
        book: "ideas",
        shorts: [],
        longs: [%{kind: "call", strike: 800.0}],
        take_profit: %{mark: 9.2, target: 10.0}
      })

    assert [%{what_to_do: w}] = Alerts.build(input(%{paper: [call]}))
    assert w =~ "double"
  end

  test "index exposure below 100% says how much to hold" do
    [alert] = Alerts.build(input(%{exposure: %{exposure: 0.72, realized_vol: 0.19}}))
    assert alert.level == :check
    assert alert.title == "Hold 72.0% of your S&P 500 holdings this month"
  end

  test "a crash put in the money is a check that the insurance is paying" do
    put =
      wheel_put(%{
        book: "crash_puts",
        spot: 680.0,
        shorts: [],
        longs: [%{kind: "put", strike: 700.0}],
        take_profit: nil
      })

    [alert] = Alerts.build(input(%{paper: [put]}))
    assert alert.level == :check
    assert alert.title =~ "insurance is paying"
  end

  test "live closes and the ideas scan are fyi" do
    alerts =
      Alerts.build(
        input(%{
          live_closes: [
            %{instrument: "NAS100_USD", direction: "Long", pnl: 229.5, pnl_percent: 0.0069}
          ],
          ideas: %{count: 16, scanned_on: ~D[2026-10-24]}
        })
      )

    assert titles(alerts) == ["Live: NAS100_USD long closed", "Options ideas scan: 16 ideas"]
    assert hd(alerts).detail =~ "+0.7%"
  end

  test "alerts are ordered act, then check, then fyi" do
    alerts =
      Alerts.build(
        input(%{
          ideas: %{count: 1, scanned_on: ~D[2026-10-24]},
          exposure: %{exposure: 0.5, realized_vol: 0.3},
          engine: {:down, "down"}
        })
      )

    assert Enum.map(alerts, & &1.level) == [:act, :check, :fyi]
  end
end
