defmodule Opus.Dashboard.Alerts do
  @moduledoc """
  The dashboard's rules: turn what `Opus.Dashboard` gathered into a list of
  alerts, most urgent first. Pure; every input is a plain map.

  Levels and their rules (thresholds are fixed here):

  **Act now (`:act`)**
    * The Rust engine is unreachable.
    * A live strategy is suspended by the circuit breaker (it stays off
      until it is reset by hand on its page).
    * An Oban job was discarded, or is retrying after an error, in the last
      24 hours.
    * The newest candle the engine stored is more than 10 minutes old while
      the forex market is open (Sunday 17:00 to Friday 17:00 New York).
    * A broker is offline in the accounts overview.
    * A paper short leg is in the money (a put below its strike, a call
      above it).
    * A paper assignment or call-away happened on the latest market date.

  **Check soon (`:check`)**
    * A paper short leg is within 2% of its strike.
    * A paper trade's 21-day check is 0–3 days away.
    * A paper trade is within 10% of its take-profit.
    * This month's index exposure (the adopted volatility rule) is below 100%.
    * A crash put is in the money (the insurance is paying).

  **For your information (`:fyi`)**
    * The paper books' events on the latest market date.
    * Live trades closed in the last 24 hours.
    * The latest options ideas scan.

  Every alert says what to do (often: nothing, and why) and links to the
  page where it is acted on.
  """

  @type level :: :act | :check | :fyi
  @type alert :: %{
          level: level(),
          title: String.t(),
          detail: String.t() | nil,
          what_to_do: String.t(),
          link: String.t() | nil
        }

  @stale_candle_seconds 600
  @near_strike 0.02
  @check_window_days 3
  @near_take_profit 0.10

  @levels [:act, :check, :fyi]

  # Plain names for the Oban workers, as the user knows the jobs.
  @workers %{
    "Opus.MarketData.OptionsChainWorker" => "Option chain snapshot",
    "Opus.Options.ScanWorker" => "Options ideas scan",
    "Opus.Options.PaperWorker" => "Options paper trading run",
    "Opus.MarketData.QuestradeBarsWorker" => "Questrade intraday bars",
    "Opus.MarketData.MassiveBarsWorker" => "US daily bars (Massive)",
    "Opus.MarketData.FinancingSnapshotWorker" => "OANDA financing snapshot",
    "Opus.MarketData.EventWindowSyncWorker" => "Event calendar sync",
    "Opus.Journal.DigestWorker" => "Weekly journal digest",
    "Opus.Trading.EvaluationWorker" => "Strategy evaluation backstop"
  }

  @doc "Every alert for the inputs, act first, then check, then fyi."
  @spec build(map()) :: [alert()]
  def build(input) do
    [
      engine(input),
      suspensions(input),
      failed_jobs(input),
      stale_candles(input),
      offline_brokers(input),
      paper_in_the_money(input),
      paper_deliveries(input),
      paper_near_strike(input),
      paper_checks_due(input),
      paper_near_take_profit(input),
      exposure(input),
      crash_puts_paying(input),
      paper_events(input),
      live_closes(input),
      ideas(input)
    ]
    |> List.flatten()
    |> Enum.sort_by(&Enum.find_index(@levels, fn level -> level == &1.level end))
  end

  @doc "A plain name for an Oban worker module."
  @spec worker_name(String.t()) :: String.t()
  def worker_name(worker),
    do: Map.get_lazy(@workers, worker, fn -> worker |> String.split(".") |> List.last() end)

  @doc """
  Whether the forex market is open: Sunday 17:00 to Friday 17:00 New York.
  Opus has no time-zone database, so New York's offset comes from the US
  daylight-saving rule (second Sunday of March to first Sunday of
  November), switched at midnight UTC rather than 2am local: off by a few
  hours on two Sundays a year, when the market is closed anyway.
  """
  @spec forex_open?(DateTime.t()) :: boolean()
  def forex_open?(%DateTime{} = now) do
    local =
      NaiveDateTime.add(DateTime.to_naive(now), ny_offset_hours(DateTime.to_date(now)) * 3600)

    case Date.day_of_week(NaiveDateTime.to_date(local)) do
      6 -> false
      7 -> local.hour >= 17
      5 -> local.hour < 17
      _ -> true
    end
  end

  defp ny_offset_hours(%Date{year: year} = date) do
    if Date.compare(date, nth_sunday(year, 3, 2)) != :lt and
         Date.compare(date, nth_sunday(year, 11, 1)) == :lt,
       do: -4,
       else: -5
  end

  defp nth_sunday(year, month, n) do
    first = Date.new!(year, month, 1)
    Date.add(first, rem(7 - Date.day_of_week(first), 7) + (n - 1) * 7)
  end

  # --- act ---------------------------------------------------------------

  defp engine(%{engine: {:down, reason}}) do
    alert(
      :act,
      "Auro (the Rust engine) is not running",
      reason,
      "Start it from auro_be (the release binary, or launchd if you've set that up). " <>
        "Live trading, the price feed and the nightly option chains stop until it's back. " <>
        "Start it once: each start spends a Questrade token.",
      nil
    )
  end

  defp engine(_input), do: []

  defp suspensions(%{suspensions: suspensions}) do
    for s <- suspensions do
      alert(
        :act,
        "#{s.name} is suspended by the circuit breaker",
        s.detail,
        "It won't trade until you reset it. Look at its recent trades on its page; if " <>
          "you still want it running, press Reset there.",
        "/strategies/#{s.id}"
      )
    end
  end

  defp suspensions(_input), do: []

  defp failed_jobs(%{failed_jobs: jobs}) do
    jobs
    |> Enum.group_by(& &1.worker)
    |> Enum.map(fn {worker, [latest | _] = failures} ->
      count = if length(failures) > 1, do: " (#{length(failures)} times)", else: ""

      alert(
        :act,
        "#{worker_name(worker)} failed#{count}",
        latest.error,
        "Check the Opus log for the full error. It runs again on its own schedule; " <>
          "if it fails two runs in a row, it needs fixing.",
        nil
      )
    end)
  end

  defp failed_jobs(_input), do: []

  defp stale_candles(%{engine: :up, candle_age: age, now: now})
       when is_integer(age) and age > @stale_candle_seconds do
    if forex_open?(now) do
      alert(
        :act,
        "Prices stopped updating #{div(age, 60)} minutes ago",
        nil,
        "Check the Rust log for OANDA errors. Strategies can't act on bars they don't " <>
          "have; a single Rust restart usually clears it.",
        "/strategies"
      )
    else
      []
    end
  end

  defp stale_candles(_input), do: []

  defp offline_brokers(%{offline_brokers: brokers}) do
    for b <- brokers do
      alert(
        :act,
        "#{b.broker} is offline",
        b.error,
        "Balances on the Accounts page are incomplete until it's back. For Questrade, " <>
          "an expired token is the usual cause: put a fresh refresh token in " <>
          "auro_be/.env and restart Rust once.",
        "/accounts"
      )
    end
  end

  defp offline_brokers(_input), do: []

  defp paper_in_the_money(%{paper: trades}) do
    for t <- trades, leg <- t.shorts, cushion(leg, t.spot) < 0 do
      alert(
        :act,
        "Paper: #{t.label} is in the money",
        "#{t.symbol} is at #{money(t.spot)}, #{pct(-cushion(leg, t.spot))} " <>
          "#{past_word(leg)} the #{money(leg.strike)} strike.",
        itm_what_to_do(t, leg),
        t.link
      )
    end
  end

  defp paper_in_the_money(_input), do: []

  defp itm_what_to_do(%{book: "wheel"} = t, %{kind: "put"} = leg) do
    "Nothing. The plan holds it: if #{t.symbol} is still below #{money(leg.strike)} at " <>
      "expiry on #{day(t.expiration)}, 100 shares are bought at #{money(leg.strike)} and the " <>
      "wheel starts selling calls on them. If you're trading this for real, don't close it early."
  end

  defp itm_what_to_do(%{book: "wheel"} = t, %{kind: "call"} = leg) do
    "Nothing. If #{t.symbol} is still above #{money(leg.strike)} at expiry, the shares are " <>
      "sold at #{money(leg.strike)}: that's the wheel finishing a cycle."
  end

  defp itm_what_to_do(t, _leg) do
    loss = if t.max_loss, do: " The most it can lose is #{money(t.max_loss)}.", else: ""

    "Nothing yet. The rules close it at the 21-day check on #{day(t.manage_on)} whatever " <>
      "its value.#{loss}"
  end

  defp paper_deliveries(%{paper_events: events}) do
    for e <- events, e.kind in ~w(assign call_away) do
      case e.kind do
        "assign" ->
          alert(
            :act,
            "Paper: assigned 100 #{e.symbol} shares",
            nil,
            "Nothing by hand: the wheel sells a covered call on them tomorrow night. " <>
              "If you were trading this for real, the shares are already in your account; " <>
              "sell one call at or above what they cost.",
            e.link
          )

        "call_away" ->
          alert(
            :act,
            "Paper: #{e.symbol} shares called away",
            nil,
            "Nothing: the cycle is finished and a new put is sold tomorrow night.",
            e.link
          )
      end
    end
  end

  defp paper_deliveries(_input), do: []

  # --- check -------------------------------------------------------------

  defp paper_near_strike(%{paper: trades}) do
    for t <- trades,
        leg <- t.shorts,
        c = cushion(leg, t.spot),
        c >= 0 and c < @near_strike do
      alert(
        :check,
        "Paper: #{t.label} is near its strike",
        "#{t.symbol} is at #{money(t.spot)}, #{pct(c)} #{safe_word(leg)} the #{money(leg.strike)} strike.",
        "Nothing yet; this is a heads-up. Read the trade's playbook so you know what " <>
          "happens if it crosses.",
        t.link
      )
    end
  end

  defp paper_near_strike(_input), do: []

  defp paper_checks_due(%{paper: trades, today: today}) do
    for t <- trades,
        t.manage_on,
        days = Date.diff(t.manage_on, today),
        days >= 0 and days <= @check_window_days do
      alert(
        :check,
        "Paper: #{t.label} reaches its 21-day check #{when_word(days)}",
        "#{day(t.manage_on)}, 21 days before expiry on #{day(t.expiration)}.",
        check_rule(t),
        t.link
      )
    end
  end

  defp paper_checks_due(_input), do: []

  defp check_rule(%{book: "wheel", shorts: [leg | _]} = t) do
    "Nothing to do by hand. That night the wheel buys it back if #{t.symbol} is " <>
      "#{safe_word(leg)} #{money(leg.strike)}, and holds it to expiry if not."
  end

  defp check_rule(%{book: "ideas"}), do: "Nothing to do by hand: the call is sold that night."

  defp check_rule(%{book: "crash_puts"}),
    do: "Nothing to do by hand: it's sold that night and next month's put is bought."

  defp check_rule(_trade),
    do: "Nothing to do by hand: the rules close it that night, whatever its value."

  defp paper_near_take_profit(%{paper: trades}) do
    for t <- trades, near_take_profit?(t.take_profit) do
      alert(
        :check,
        "Paper: #{t.label} is close to its take-profit",
        nil,
        take_profit_words(t.take_profit),
        t.link
      )
    end
  end

  defp paper_near_take_profit(_input), do: []

  # A short-premium trade closes once it can be bought back for the target
  # or less; a long call once its bid reaches double.
  defp near_take_profit?(%{close_cost: cost, target: target}) when is_number(cost),
    do: cost > target and cost <= target * (1 + @near_take_profit)

  defp near_take_profit?(%{mark: mark, target: target}) when is_number(mark),
    do: mark < target and mark >= target * (1 - @near_take_profit)

  defp near_take_profit?(_take_profit), do: false

  defp take_profit_words(%{close_cost: _cost, target: target}),
    do:
      "Nothing: it closes itself the first night it can be bought back for " <>
        "#{money(target)} a share or less."

  defp take_profit_words(%{target: target}),
    do: "Nothing: it's sold the first night its bid reaches #{money(target)} (double)."

  defp exposure(%{exposure: %{exposure: share, realized_vol: vol}}) when share < 1.0 do
    alert(
      :check,
      "Hold #{pct(share)} of your S&P 500 holdings this month",
      "Last month's volatility was #{pct(vol)}, against the rule's 16% target.",
      "The volatility rule you adopted says: keep #{pct(share)} of your S&P 500 index " <>
        "holdings invested and the rest in cash until the start of next month.",
      "/accounts"
    )
  end

  defp exposure(_input), do: []

  defp crash_puts_paying(%{paper: trades}) do
    for %{book: "crash_puts"} = t <- trades,
        leg <- t.longs,
        cushion(leg, t.spot) < 0 do
      alert(
        :check,
        "Paper: crash insurance is paying",
        "#{t.symbol} is at #{money(t.spot)}, below the #{money(leg.strike)} put.",
        "Nothing: it's held and rolled at the 21-day mark (#{day(t.manage_on)}), " <>
          "when the gain is taken.",
        t.link
      )
    end
  end

  defp crash_puts_paying(_input), do: []

  # --- fyi ---------------------------------------------------------------

  defp paper_events(%{paper_events: events}) do
    for e <- events, e.kind in ~w(open close expire) do
      alert(
        :fyi,
        "Paper #{book_name(e.book)}: #{e.symbol} #{event_word(e.kind)}",
        "#{day(e.on)} · #{signed_money(e.cash)}",
        "Nothing; the books run themselves.",
        e.link
      )
    end
  end

  defp paper_events(_input), do: []

  defp live_closes(%{live_closes: closes}) do
    for c <- closes do
      alert(
        :fyi,
        "Live: #{c.instrument} #{String.downcase(c.direction || "")} closed",
        "#{signed_pct(c.pnl_percent)}#{if c.pnl, do: " · #{signed_money(c.pnl)}", else: ""}",
        "Nothing; see the Journal for the details.",
        "/journal"
      )
    end
  end

  defp live_closes(_input), do: []

  defp ideas(%{ideas: %{count: count, scanned_on: %Date{} = on}}) do
    alert(
      :fyi,
      "Options ideas scan: #{count} ideas",
      "Scanned #{day(on)}.",
      "Nothing; browse them on the Options page if you're curious.",
      "/options"
    )
  end

  defp ideas(_input), do: []

  # --- helpers -----------------------------------------------------------

  defp alert(level, title, detail, what_to_do, link),
    do: %{level: level, title: title, detail: detail, what_to_do: what_to_do, link: link}

  # How far the underlying is from a strike as a share of its price, on the
  # side where a short leg expires worthless (negative: in the money).
  defp cushion(_leg, spot) when not is_number(spot), do: 1.0
  defp cushion(%{kind: "put", strike: strike}, spot), do: (spot - strike) / spot
  defp cushion(%{kind: "call", strike: strike}, spot), do: (strike - spot) / spot

  defp safe_word(%{kind: "put"}), do: "above"
  defp safe_word(%{kind: "call"}), do: "below"

  defp past_word(%{kind: "put"}), do: "below"
  defp past_word(%{kind: "call"}), do: "above"

  defp when_word(0), do: "today"
  defp when_word(1), do: "tomorrow"
  defp when_word(days), do: "in #{days} days"

  defp book_name("wheel"), do: "wheel"
  defp book_name("put_spread"), do: "put spreads"
  defp book_name("iron_condor"), do: "iron condors"
  defp book_name("ideas"), do: "ideas"
  defp book_name("crash_puts"), do: "crash puts"
  defp book_name(other), do: other

  defp event_word("open"), do: "opened"
  defp event_word("close"), do: "closed"
  defp event_word("expire"), do: "expired"

  defp day(%Date{} = date), do: Calendar.strftime(date, "%b %-d")
  defp day(_), do: "—"

  defp money(value), do: OpusWeb.Format.money(value)
  defp pct(value), do: OpusWeb.Format.pct(value)
  defp signed_pct(nil), do: "—"
  defp signed_pct(value), do: OpusWeb.Format.signed_pct(value)

  defp signed_money(value) when is_number(value) and value < 0, do: "−" <> money(abs(value))
  defp signed_money(value) when is_number(value), do: "+" <> money(value)
  defp signed_money(_), do: "—"
end
