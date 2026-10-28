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
        live_opens: [],
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
        key: "wheel:1",
        symbol: "SPY",
        label: "SPY $734.00 put (wheel)",
        link: "/options?view=paper&book=wheel&trade=SPY",
        spot: 761.0,
        expiration: ~D[2026-11-30],
        manage_on: ~D[2026-11-09],
        shorts: [%{id: 1, kind: "put", strike: 734.0}],
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
        longs: [%{id: 2, kind: "put", strike: 724.0}],
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
        key: "wheel:event:9",
        cash: -73_400.0,
        on: ~D[2026-11-30],
        link: "/x"
      },
      %{
        book: "iron_condor",
        symbol: "QQQ",
        kind: "close",
        key: "iron_condor:5:close",
        label: "QQQ iron condor 540/545/600/605",
        cash: nil,
        pnl: 212.4,
        on: ~D[2026-11-30],
        link: "/y"
      }
    ]

    [act, fyi] = Alerts.build(input(%{paper_events: events}))
    assert act.level == :act and act.title =~ "assigned 100 SPY"
    assert fyi.level == :fyi
    assert fyi.title == "Paper iron condors: QQQ iron condor 540/545/600/605 closed"
    assert fyi.detail == "Nov 30 · made $212.40"
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
        longs: [%{id: 4, kind: "call", strike: 800.0}],
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
        longs: [%{id: 3, kind: "put", strike: 700.0}],
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
            %{
              id: "c1",
              instrument: "NAS100_USD",
              direction: "Long",
              pnl: 229.5,
              pnl_percent: 0.0069
            }
          ],
          ideas: %{count: 16, scanned_on: ~D[2026-10-24]}
        })
      )

    assert titles(alerts) == ["Live: NAS100 long closed", "Options ideas scan: 16 ideas"]
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

  test "losing half the most a trade can lose is act-now, crash puts aside" do
    spread =
      wheel_put(%{
        book: "put_spread",
        key: "put_spread:7",
        label: "SPY put spread 734/724",
        longs: [%{id: 2, kind: "put", strike: 724.0}],
        max_loss: 800.0,
        pnl: -400.0,
        take_profit: nil
      })

    [alert] = Alerts.build(input(%{paper: [spread]}))
    assert alert.level == :act
    assert alert.key == "big_loss:put_spread:7"
    assert alert.title == "Paper: SPY put spread 734/724 is down $400.00"
    assert alert.what_to_do =~ "up to $400.00 more"

    assert Alerts.build(input(%{paper: [%{spread | pnl: -399.0}]})) == []

    crash = %{
      spread
      | book: "crash_puts",
        shorts: [],
        longs: [%{id: 3, kind: "put", strike: 600.0}]
    }

    assert Alerts.build(input(%{paper: [crash]})) == []
  end

  test "an opened paper trade says how to copy it" do
    legs = [
      %{
        side: "short",
        kind: "put",
        strike: 640.0,
        quantity: 1,
        open_price: 3.1,
        symbol: "SPY",
        expiration: ~D[2026-11-28]
      },
      %{
        side: "long",
        kind: "put",
        strike: 630.0,
        quantity: 1,
        open_price: 1.85,
        symbol: "SPY",
        expiration: ~D[2026-11-28]
      }
    ]

    open = %{
      book: "put_spread",
      key: "put_spread:8:open",
      symbol: "SPY",
      kind: "open",
      on: ~D[2026-10-27],
      label: "SPY put spread 640/630",
      legs: legs,
      link: "/z"
    }

    [alert] = Alerts.build(input(%{paper_events: [open]}))
    assert alert.level == :fyi
    assert alert.title == "Paper put spreads: opened SPY put spread 640/630"

    assert alert.detail =~
             "**Opened Oct 27:** Sell 1 SPY Nov 28 $640.00 put, Buy 1 SPY Nov 28 $630.00 put · " <>
               "net $1.25 credit a share ($125.00)"

    assert alert.detail =~
             "**The bet:** keeps the $125.00 credit if SPY stays above $640.00 until Nov 28. " <>
               "The most it can lose is $875.00."

    assert alert.detail =~ "**What happens next:** it's closed once it can be bought back"

    assert alert.what_to_do =~ "Spreads need a Wealthsimple margin account"
    assert Alerts.notify?(alert)
    refute Alerts.on_dashboard?(alert)
  end

  test "a half sold at double says to sell half a copied trade" do
    half = %{
      book: "ideas_half",
      key: "ideas_half:4:half",
      symbol: "QQQ",
      kind: "half",
      on: ~D[2026-10-30],
      label: "QQQ $650.00 call",
      sold: %{quantity: 1, open_price: 6.12, close_price: 12.5},
      kept: %{quantity: 1},
      manage_on: ~D[2026-11-13],
      link: "/z"
    }

    [alert] = Alerts.build(input(%{paper_events: [half]}))
    assert alert.title == "Paper ideas (half at double): sold half of QQQ $650.00 call at double"
    assert alert.detail =~ "sold 1 of 2 at $12.50, double the $6.12 paid: $1,250.00 back"
    assert alert.what_to_do =~ "sell half your contracts now at $12.50 or better"
    assert alert.what_to_do =~ "Nov 13, or sooner if it falls back to $6.12"
    assert Alerts.notify?(alert)
    assert Alerts.on_dashboard?(alert)
  end

  test "an opened crash put says what it bets on and what happens next" do
    leg = %{
      side: "long",
      kind: "put",
      strike: 706.0,
      quantity: 2,
      open_price: 2.44,
      symbol: "SPY",
      expiration: ~D[2026-11-30]
    }

    open = %{
      book: "crash_puts_half",
      key: "crash_puts_half:9:open",
      symbol: "SPY",
      kind: "open",
      on: ~D[2026-10-27],
      label: "SPY $706.00 crash put",
      spot: 766.2,
      legs: [leg],
      link: "/z"
    }

    [alert] = Alerts.build(input(%{paper_events: [open]}))
    assert alert.title == "Paper crash puts (half at double): opened 2 × SPY $706.00 crash put"

    assert alert.detail =~
             "**Bought Oct 27:** Buy 2 SPY Nov 30 $706.00 put at $2.44 a share ($488.00 paid)"

    assert alert.detail =~
             "pays off if SPY falls below $706.00 (it's $766.20 now, 7.9% lower) before Nov 30"

    assert alert.detail =~ "if it doubles ($4.88), half are sold"
    assert alert.detail =~ "Whatever is left is sold on Nov 9 (21 days left)"
  end

  test "a job's error loses Oban's leading ** so Discord doesn't bold it" do
    jobs = [%{worker: "Opus.Dashboard.NotifyWorker", error: "** (Oban.PerformError) closed"}]
    [alert] = Alerts.build(input(%{failed_jobs: jobs}))
    assert alert.detail == "(Oban.PerformError) closed"
  end

  test "a live open says what was bought, when, and where the stop is" do
    open = %{
      id: "x",
      label: "NAS100 long",
      direction: "Long",
      units: "1.00",
      entry_price: 29_674.4,
      entry_time: ~U[2026-10-27 19:00:03Z],
      stop_loss_price: 29_080.12954074413,
      link: "/j"
    }

    [alert] = Alerts.build(input(%{live_opens: [open]}))
    assert alert.detail == "Bought 1 at 29,674.4 at 15:00. Stop at 29,080.1, 2.0% below."
  end

  test "a live close says both prices, the result and why" do
    close = %{
      id: "y",
      instrument: "NAS100_USD",
      direction: "Long",
      status: "closed",
      units: "1.00",
      entry_price: 29_579.1,
      exit_price: 29_639.8,
      entry_time: ~U[2026-10-27 15:00:03Z],
      exit_time: ~U[2026-10-27 18:30:02Z],
      exit_reason:
        ~s[CompositeExit (ports={"na": {"session_close": false, "short": false, ] <>
          ~s["exit_long": true, "long": false, "exit_short": true}})],
      pnl: 84.4427,
      pnl_percent: 0.0021
    }

    [alert] = Alerts.build(input(%{live_closes: [close]}))

    assert alert.detail =~
             "Bought at 29,579.1 at 11:00, sold at 29,639.8 at 14:30 New York: +0.2% · +$84.44."

    assert alert.detail =~ "Why: the move faded."
  end

  test "the ideas scan stays off the phone" do
    [ideas] = Alerts.build(input(%{ideas: %{count: 3, scanned_on: ~D[2026-10-24]}}))
    refute Alerts.notify?(ideas)
    [engine] = Alerts.build(input(%{engine: {:down, "down"}}))
    assert Alerts.notify?(engine)
  end
end
