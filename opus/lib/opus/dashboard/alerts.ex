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
    * The engine's account numbers (NAV) are more than 10 minutes old while
      the forex market is open.
    * OANDA has an open trade the engine isn't tracking.
    * Part of the dashboard failed to load (its other parts still show).
    * A broker is offline in the accounts overview.
    * A paper short leg is in the money (a put below its strike, a call
      above it).
    * A paper assignment or call-away happened on the latest market date.
    * A paper trade has lost half or more of the most it can lose (crash
      puts aside: losing their premium is their plan).

  **Check soon (`:check`)**
    * The OANDA account nets opposite trades (hedging off).
    * A live strategy isn't behaving like its backtest (`Opus.Trading.Drift`).
    * A paper short leg is within 2% of its strike.
    * A paper trade's 21-day check is 0–3 days away.
    * A paper trade is within 10% of its take-profit.
    * This month's index exposure (the adopted volatility rule) is below 100%.
    * A crash put is in the money (the insurance is paying).

  **For your information (`:fyi`)**
    * Paper trades that opened, closed or expired on the latest market date.
      An open says how to copy it by hand.
    * Live trades opened or closed in the last 24 hours.

  Opens go to the phone only (`on_dashboard?/1`); the ideas scan stays on
  the dashboard only (`notify?/1`).
    * The latest options ideas scan.

  Every alert says what to do (often: nothing, and why) and links to the
  page where it is acted on. Its `key` names the thing it is about (a trade
  leg, a job, the engine), so the same alert can be recognised from one
  check to the next while its wording changes.
  """

  import OpusWeb.Format, only: [day: 1, money: 1, pct: 1, signed_money: 1, signed_pct: 1]

  alias Opus.Options.Paper.{Legs, Pick, Wheel}

  @type level :: :act | :check | :fyi
  @type alert :: %{
          level: level(),
          key: String.t(),
          title: String.t(),
          detail: String.t() | nil,
          what_to_do: String.t(),
          link: String.t() | nil
        }

  @stale_candle_seconds 600
  @stale_nav_seconds 600
  @near_strike 0.02
  @check_window_days 3
  @near_take_profit 0.10
  @big_loss 0.5

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
    "Opus.Trading.EvaluationWorker" => "Strategy evaluation backstop",
    "Opus.Pipeline.PromoteWorker" => "Promotion of a tested strategy"
  }

  @doc "Every alert for the inputs, act first, then check, then fyi."
  @spec build(map()) :: [alert()]
  def build(input) do
    [
      engine(input),
      account_pause(input),
      suspensions(input),
      failed_jobs(input),
      stale_candles(input),
      stale_nav(input),
      untracked_trades(input),
      failed_sections(input),
      hedging(input),
      drift(input),
      offline_brokers(input),
      paper_in_the_money(input),
      paper_deliveries(input),
      paper_big_losses(input),
      paper_near_strike(input),
      paper_checks_due(input),
      paper_near_take_profit(input),
      exposure(input),
      crash_puts_paying(input),
      paper_events(input),
      paper_halves(input),
      paper_opens(input),
      live_opens(input),
      live_closes(input),
      ideas(input)
    ]
    |> List.flatten()
    |> Enum.sort_by(&Enum.find_index(@levels, fn level -> level == &1.level end))
  end

  @doc """
  Whether an alert is worth a phone notification: all but the ideas scan,
  which is for browsing, not acting on.
  """
  @spec notify?(alert()) :: boolean()
  def notify?(%{key: "ideas:" <> _}), do: false
  def notify?(_alert), do: true

  @doc """
  Whether an alert belongs on the dashboard: all but opens, which the open
  positions table already shows (marked new). They go to the phone only.
  """
  @spec on_dashboard?(alert()) :: boolean()
  def on_dashboard?(%{key: "opened:" <> _}), do: false
  def on_dashboard?(_alert), do: true

  @doc "A plain name for an Oban worker module."
  @spec worker_name(String.t()) :: String.t()
  def worker_name(worker),
    do: Map.get_lazy(@workers, worker, fn -> worker |> String.split(".") |> List.last() end)

  @doc "Whether the forex market is open: Sunday 17:00 to Friday 17:00 New York."
  @spec forex_open?(DateTime.t()) :: boolean()
  def forex_open?(%DateTime{} = now) do
    local = Opus.Clock.local(now)

    case Date.day_of_week(local) do
      6 -> false
      7 -> local.hour >= 17
      5 -> local.hour < 17
      _ -> true
    end
  end

  # --- act ---------------------------------------------------------------

  defp engine(%{engine: {:down, reason}}) do
    alert(
      :act,
      "engine",
      "Auro (the Rust engine) is not running",
      reason,
      "Start it from auro_be (the release binary, or launchd if you've set that up). " <>
        "Live trading, the price feed and the option chain snapshots stop until it's back. " <>
        "Start it once: each start spends a Questrade token.",
      nil
    )
  end

  defp engine(_input), do: []

  defp account_pause(%{account_pause: %{down: down, peak: peak, nav: nav, limit: limit}}) do
    [
      alert(
        :act,
        "account_pause",
        "Trading is paused: the account fell #{pct(down)} from its peak",
        "NAV #{money(nav)}, peak #{money(peak)}; the limit is #{limit}%.",
        "No strategy opens a trade until you resume. Open trades keep their stops. " <>
          "Look at what lost before resuming on the Strategies page.",
        "/strategies"
      )
    ]
  end

  defp account_pause(_input), do: []

  defp suspensions(%{suspensions: suspensions}) do
    for s <- suspensions do
      alert(
        :act,
        "suspended:#{s.id}",
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

      :act
      |> alert(
        "job_failed:#{worker}",
        "#{worker_name(worker)} failed#{count}",
        error_words(latest.error),
        "Check the Opus log for the full error. It runs again on its own schedule; " <>
          "if it fails two runs in a row, it needs fixing. Clear it once you've looked.",
        nil
      )
      |> Map.put(:clear_worker, worker)
    end)
  end

  defp failed_jobs(_input), do: []

  # Oban's error text starts with "** ", which Discord reads as bold.
  defp error_words(nil), do: nil
  defp error_words(error), do: error |> String.trim_leading("** ") |> String.slice(0, 500)

  defp stale_candles(%{engine: :up, candle_age: age, now: now})
       when is_integer(age) and age > @stale_candle_seconds do
    if forex_open?(now) do
      alert(
        :act,
        "stale_candles",
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

  defp stale_nav(%{engine: :up, nav_age: age, now: now})
       when is_integer(age) and age > @stale_nav_seconds do
    if forex_open?(now) do
      alert(
        :act,
        "stale_nav",
        "Account numbers stopped updating #{div(age, 60)} minutes ago",
        nil,
        "The drawdown pause and trade sizing work from the last NAV stored, which is now " <>
          "out of date. Check the Rust log for OANDA account errors; a Rust restart usually " <>
          "clears it.",
        "/safety"
      )
    else
      []
    end
  end

  defp stale_nav(_input), do: []

  defp untracked_trades(%{untracked_trades: trades}) do
    for t <- trades do
      alert(
        :act,
        "untracked:#{t.id}",
        "OANDA has a trade Auro isn't managing",
        "Trade #{t.id}: #{t.instrument}, #{t.units} units.",
        "It keeps its stop at OANDA but none of Auro's exit rules run on it. Close it in " <>
          "OANDA, or tell Claude if Auro should pick it up.",
        nil
      )
    end
  end

  defp untracked_trades(_input), do: []

  defp failed_sections(%{failed_sections: sections}) do
    for name <- sections do
      alert(
        :act,
        "dashboard_section:#{name}",
        "Part of the dashboard failed to load: #{name}",
        nil,
        "The rest of the dashboard and its alerts still work, but nothing about #{name} " <>
          "shows until this clears. Check the Opus log for the error.",
        nil
      )
    end
  end

  defp failed_sections(_input), do: []

  defp offline_brokers(%{offline_brokers: brokers}) do
    for b <- brokers do
      alert(
        :act,
        "broker_offline:#{b.broker}",
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
        "itm:#{leg.id}",
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
            "paper:#{e.key}",
            "Paper: assigned 100 #{e.symbol} shares",
            nil,
            "Nothing by hand: the wheel sells a covered call on them at its 10:30 check. " <>
              "If you were trading this for real, the shares are already in your account; " <>
              "sell one call at or above what they cost.",
            e.link
          )

        "call_away" ->
          alert(
            :act,
            "paper:#{e.key}",
            "Paper: #{e.symbol} shares called away",
            nil,
            "Nothing: the cycle is finished and a new put is sold at the 10:30 check.",
            e.link
          )
      end
    end
  end

  defp paper_deliveries(_input), do: []

  defp paper_big_losses(%{paper: trades}) do
    for t <- trades, t.book not in ~w(crash_puts crash_puts_half), losing_big?(t) do
      lost = -t.pnl

      alert(
        :act,
        "big_loss:#{t.key}",
        "Paper: #{t.label} is down #{money(lost)}",
        "That's #{pct(lost / t.max_loss)} of the most it can lose (#{money(t.max_loss)}).",
        big_loss_what_to_do(t, lost),
        t.link
      )
    end
  end

  defp paper_big_losses(_input), do: []

  # The ideas books stop a bought option out at half what it cost (at the
  # next 10:30 check); the others hold to their 21-day check.
  defp big_loss_what_to_do(%{book: book} = t, lost) when book in ~w(ideas ideas_half),
    do:
      "Nothing for the paper book: its rule sells once the option is worth half what it cost, " <>
        "at the next 10:30 check. If you're trading this for real, do the same: about " <>
        "#{money(lost)} is lost, and holding risks up to #{money(t.max_loss - lost)} more."

  defp big_loss_what_to_do(t, lost),
    do:
      "The paper rules don't stop this trade out early: they hold it to the 21-day check on " <>
        "#{day(t.manage_on)}. If you're trading this for real, decide now: closing locks in " <>
        "about #{money(lost)} lost; holding risks up to #{money(t.max_loss - lost)} more."

  defp losing_big?(%{pnl: pnl, max_loss: max})
       when is_number(pnl) and is_number(max) and max > 0,
       do: -pnl >= max * @big_loss

  defp losing_big?(_trade), do: false

  # --- check -------------------------------------------------------------

  defp hedging(%{hedging: false}) do
    alert(
      :check,
      "hedging_off",
      "Your OANDA account nets opposite trades",
      "Hedging is off, so a buy and a sell on one instrument cancel each other out.",
      "Auro won't open a trade in the opposite direction while one is open on that " <>
        "instrument, so some signals are skipped. Turning hedging on for the OANDA account " <>
        "removes the conflict.",
      nil
    )
  end

  defp hedging(_input), do: []

  defp drift(%{drift: rows}) do
    for d <- rows do
      alert(
        :check,
        "drift:#{d.id}",
        "#{d.name} on #{d.instrument} isn't behaving like its backtest",
        d.detail,
        "Read the check on its page. If it still looks wrong after a few more trades, " <>
          "switch it off; if it's a slow patch, leave it: the circuit breaker still watches it.",
        "/strategies/#{d.id}"
      )
    end
  end

  defp drift(_input), do: []

  defp paper_near_strike(%{paper: trades}) do
    for t <- trades,
        leg <- t.shorts,
        c = cushion(leg, t.spot),
        c >= 0 and c < @near_strike do
      alert(
        :check,
        "near_strike:#{leg.id}",
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
        "check_due:#{t.key}",
        "Paper: #{t.label} reaches its 21-day check #{when_word(days)}",
        "#{day(t.manage_on)}, 21 days before expiry on #{day(t.expiration)}.",
        check_rule(t),
        t.link
      )
    end
  end

  defp paper_checks_due(_input), do: []

  defp check_rule(%{book: "wheel", shorts: [leg | _]} = t) do
    "Nothing to do by hand. That day's check buys it back if #{t.symbol} is " <>
      "#{safe_word(leg)} #{money(leg.strike)}, and holds it to expiry if not."
  end

  defp check_rule(%{book: book}) when book in ~w(ideas ideas_half),
    do: "Nothing to do by hand: the call is sold at that day's check."

  defp check_rule(%{book: book}) when book in ~w(crash_puts crash_puts_half),
    do: "Nothing to do by hand: it's sold at that day's check and next month's put is bought."

  defp check_rule(_trade),
    do: "Nothing to do by hand: that day's check closes it, whatever its value."

  defp paper_near_take_profit(%{paper: trades}) do
    for t <- trades, near_take_profit?(t.take_profit) do
      alert(
        :check,
        "near_take_profit:#{t.key}",
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
      "Nothing: it closes itself at the first check it can be bought back for " <>
        "#{money(target)} a share or less."

  defp take_profit_words(%{target: target, half: true}),
    do:
      "Nothing yet: at the first check its bid reaches #{money(target)} (double), half the " <>
        "contracts are sold, which pays back what the whole position cost."

  defp take_profit_words(%{target: target}),
    do: "Nothing: it's sold at the first check its bid reaches #{money(target)} (double)."

  defp exposure(%{exposure: %{exposure: share, realized_vol: vol}}) when share < 1.0 do
    alert(
      :check,
      "exposure:#{pct(share)}",
      "Hold #{pct(share)} of your S&P 500 holdings this month",
      "Last month's volatility was #{pct(vol)}, against the rule's 16% target.",
      "The volatility rule you adopted says: keep #{pct(share)} of your S&P 500 index " <>
        "holdings invested and the rest in cash until the start of next month.",
      "/accounts"
    )
  end

  defp exposure(_input), do: []

  defp crash_puts_paying(%{paper: trades}) do
    for %{book: book} = t <- trades,
        book in ~w(crash_puts crash_puts_half),
        leg <- t.longs,
        cushion(leg, t.spot) < 0 do
      alert(
        :check,
        "crash_put_paying:#{leg.id}",
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
    for e <- events, e.kind in ~w(close expire) do
      alert(
        :fyi,
        "paper:#{e.key}",
        "Paper #{book_name(e.book)}: #{e.label} #{event_word(e.kind)}",
        "#{day(e.on)} · #{outcome(e)}",
        "Nothing; the books run themselves.",
        e.link
      )
    end
  end

  defp paper_events(_input), do: []

  defp paper_halves(%{paper_events: events}) do
    for %{kind: "half", sold: sold, kept: kept} = e <- events do
      alert(
        :fyi,
        "paper:#{e.key}",
        "Paper #{book_name(e.book)}: sold half of #{e.label} at double",
        "#{day(e.on)} · sold #{sold.quantity} of #{sold.quantity + kept.quantity} at " <>
          "#{money(sold.close_price)}, double the #{money(sold.open_price)} paid: " <>
          "#{money(sold.close_price * Pick.multiplier() * sold.quantity)} back, about what all " <>
          "#{sold.quantity + kept.quantity} cost.",
        "If you copied this trade, sell half your contracts now at #{money(sold.close_price)} " <>
          "or better. The rest rides for free: it's sold at the 21-day check on " <>
          "#{day(e.manage_on)}, or sooner if it falls back to #{money(sold.open_price)}.",
        e.link
      )
    end
  end

  defp paper_halves(_input), do: []

  defp paper_opens(%{paper_events: events}) do
    for %{kind: "open"} = e <- events do
      alert(
        :fyi,
        "opened:#{e.key}",
        "Paper #{book_name(e.book)}: opened #{count_words(e.legs)}#{e.label}",
        Enum.join(
          [
            "**#{opened_word(e.legs)} #{day(e.on)}:** #{order_words(e.legs)}",
            "**The bet:** #{bet_words(e.legs, e[:symbol], e[:spot])}",
            "**What happens next:** #{next_words(e.book, e.legs)}"
          ],
          "\n"
        ),
        copy_words(e.legs),
        e.link
      )
    end
  end

  defp paper_opens(_input), do: []

  defp live_opens(%{live_opens: opens}) do
    for o <- opens do
      alert(
        :fyi,
        "opened:live:#{o.id}",
        "Live: #{o.label} opened",
        live_open_words(o),
        "Nothing; the engine manages it and closes it on its own.",
        o.link
      )
    end
  end

  defp live_opens(_input), do: []

  defp live_closes(%{live_closes: closes}) do
    for c <- closes do
      alert(
        :fyi,
        "live_closed:#{c.id}",
        "Live: #{Opus.Journal.TradeStory.market(c)} #{String.downcase(c.direction || "")} closed",
        live_close_words(c),
        "Nothing; see the Journal for the details.",
        "/journal"
      )
    end
  end

  defp live_closes(_input), do: []

  # "Bought 1 at 29,674.4 at 15:00 New York. Stop at 29,080.1, 2.0% below."
  defp live_open_words(o) do
    entry =
      "#{side_verb(o[:direction], :open)} #{units(o[:units])}at " <>
        "#{OpusWeb.Format.price(o[:entry_price])}#{at_clock(o[:entry_time])}."

    stop =
      case {o.stop_loss_price, o[:entry_price]} do
        {nil, _entry} ->
          nil

        {stop, entry} when is_number(entry) and entry > 0 ->
          "Stop at #{OpusWeb.Format.price(stop)}, #{pct(abs(stop / entry - 1))} " <>
            "#{if stop < entry, do: "below", else: "above"}."

        {stop, _entry} ->
          "Stop at #{OpusWeb.Format.price(stop)}."
      end

    [entry, stop] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  # "Bought at 29,579.1 at 11:00, sold at 29,639.8 at 14:30 New York:
  # +0.2% · +$84.44. Why: the move faded."
  defp live_close_words(c) do
    result = "#{signed_pct(c.pnl_percent)}#{if c.pnl, do: " · #{signed_money(c.pnl)}", else: ""}"

    "#{side_verb(c[:direction], :open)} at #{OpusWeb.Format.price(c[:entry_price])}" <>
      "#{at_clock(c[:entry_time])}, #{side_verb(c[:direction], :close)} at " <>
      "#{OpusWeb.Format.price(c[:exit_price])}#{at_clock(c[:exit_time])} New York: " <>
      "#{result}.#{why(c)}"
  end

  defp why(%{exit_reason: reason} = c) when is_binary(reason),
    do: " Why: #{String.downcase(Opus.Journal.TradeStory.exit_label(c), :ascii)}."

  defp why(_close), do: ""

  defp side_verb("Short", :open), do: "Sold"
  defp side_verb("Short", :close), do: "bought back"
  defp side_verb(_long, :open), do: "Bought"
  defp side_verb(_long, :close), do: "sold"

  # Units are stored as text ("1.00", "0.5").
  defp units(units) when is_binary(units) do
    case Float.parse(units) do
      {n, _rest} when n == trunc(n) -> "#{trunc(n)} "
      {n, _rest} -> "#{n} "
      :error -> ""
    end
  end

  defp units(_units), do: ""

  defp at_clock(%DateTime{} = at), do: " at #{OpusWeb.Format.clock(Opus.Clock.local(at))}"
  defp at_clock(_at), do: ""

  defp ideas(%{ideas: %{count: count, scanned_on: %Date{} = on}}) do
    alert(
      :fyi,
      "ideas:#{on}",
      "Options ideas scan: #{count} ideas",
      "Scanned #{day(on)}.",
      "Nothing; browse them on the Options page if you're curious.",
      "/options?view=workbench"
    )
  end

  defp ideas(_input), do: []

  # --- helpers -----------------------------------------------------------

  defp alert(level, key, title, detail, what_to_do, link),
    do: %{
      level: level,
      key: key,
      title: title,
      detail: detail,
      what_to_do: what_to_do,
      link: link
    }

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
  defp book_name("ideas_half"), do: "ideas (half at double)"
  defp book_name("crash_puts"), do: "crash puts"
  defp book_name("crash_puts_half"), do: "crash puts (half at double)"
  defp book_name(other), do: other

  defp event_word("close"), do: "closed"
  defp event_word("expire"), do: "expired"

  defp outcome(%{pnl: pnl}) when is_number(pnl) and pnl < 0, do: "lost #{money(abs(pnl))}"
  defp outcome(%{pnl: pnl}) when is_number(pnl), do: "made #{money(pnl)}"
  defp outcome(%{cash: cash}) when is_number(cash) and cash < 0, do: "paid #{money(abs(cash))}"
  defp outcome(%{cash: cash}) when is_number(cash) and cash > 0, do: "received #{money(cash)}"
  defp outcome(_event), do: "nothing changed hands"

  # The order as you'd type it: the legs sold, then those bought, then the
  # net price for a spread.
  defp opened_word(legs) do
    case legs |> Enum.map(& &1.side) |> Enum.uniq() do
      ["long"] -> "Bought"
      ["short"] -> "Sold"
      _ -> "Opened"
    end
  end

  defp count_words([%{quantity: n}]) when n > 1, do: "#{n} × "
  defp count_words(_legs), do: ""

  defp order_words([leg]) do
    side = if leg.side == "short", do: "taken in", else: "paid"

    "#{leg_words(leg)} at #{money(leg.open_price)} a share " <>
      "(#{money(leg.open_price * Pick.multiplier() * leg.quantity)} #{side})"
  end

  defp order_words(legs) do
    net = Legs.net_premium(legs)
    side = if net >= 0, do: "credit", else: "debit"

    legs
    |> Enum.sort_by(&{&1.side != "short", &1.strike})
    |> Enum.map_join(", ", &leg_words/1)
    |> Kernel.<>(" · net #{money(abs(net))} #{side} a share (#{money(abs(net) * 100)})")
  end

  defp leg_words(leg) do
    verb = if leg.side == "short", do: "Sell", else: "Buy"

    "#{verb} #{leg.quantity} #{leg.symbol} #{day(leg.expiration)} #{money(leg.strike)} #{leg.kind}"
  end

  # What the trade is betting on, in plain words, from where the underlying
  # stood when it opened.
  defp bet_words([%{side: "long", kind: "put"} = leg], symbol, spot) do
    "pays off if #{symbol} falls below #{money(leg.strike)}#{away(leg.strike, spot)} " <>
      "before #{day(leg.expiration)}. If it doesn't, it slowly loses value; the most it can " <>
      "lose is the #{money(paid(leg))} paid."
  end

  defp bet_words([%{side: "long", kind: "call"} = leg], symbol, spot) do
    "pays off if #{symbol} rises above #{money(leg.strike)}#{away(leg.strike, spot)} " <>
      "before #{day(leg.expiration)}. If it doesn't, it slowly loses value; the most it can " <>
      "lose is the #{money(paid(leg))} paid."
  end

  defp bet_words([%{side: "short", kind: "put"} = leg], symbol, spot) do
    "keeps the #{money(paid(leg))} if #{symbol} stays above #{money(leg.strike)}" <>
      "#{away(leg.strike, spot)} until #{day(leg.expiration)}. Below it, you buy " <>
      "#{leg.quantity * Pick.multiplier()} shares at #{money(leg.strike)}."
  end

  defp bet_words([%{side: "short", kind: "call"} = leg], symbol, spot) do
    "keeps the #{money(paid(leg))} if #{symbol} stays below #{money(leg.strike)}" <>
      "#{away(leg.strike, spot)} until #{day(leg.expiration)}. Above it, the shares are " <>
      "sold at #{money(leg.strike)}."
  end

  defp bet_words(legs, symbol, spot) do
    %{net: net, max_loss: max_loss} = Legs.summary(legs)
    shorts = legs |> Enum.filter(&(&1.side == "short")) |> Enum.sort_by(& &1.strike)

    range =
      case shorts do
        [%{kind: "put"} = put] -> "above #{money(put.strike)}#{away(put.strike, spot)}"
        [low, high] -> "between #{money(low.strike)} and #{money(high.strike)}"
        _ -> "where it is"
      end

    "keeps the #{money(net)} credit if #{symbol} stays #{range} until " <>
      "#{day(hd(legs).expiration)}. The most it can lose is #{money(max_loss || 0.0)}."
  end

  defp away(_strike, spot) when not is_number(spot), do: ""

  defp away(strike, spot),
    do:
      " (it's #{money(spot)} now, #{pct(abs(strike / spot - 1))} " <>
        "#{if strike < spot, do: "lower", else: "higher"})"

  defp paid(leg), do: leg.open_price * Pick.multiplier() * leg.quantity

  # What the book's rules do with the trade from here.
  defp next_words("wheel", [leg]) do
    "it's bought back once it costs #{money(Wheel.take_profit_price(leg))} a share (half " <>
      "what it sold for), checked again on #{day(Wheel.manage_on(leg))} (21 days left), " <>
      "otherwise held to expiry."
  end

  defp next_words(book, legs) when book in ~w(put_spread iron_condor) do
    "it's closed once it can be bought back for half the credit, or on " <>
      "#{day(manage_day(legs))} (21 days left) whatever it's worth."
  end

  defp next_words("ideas", [leg]) do
    "sold if it doubles (#{money(leg.open_price * 2)}), if it halves " <>
      "(#{money(leg.open_price / 2)}), or on #{day(manage_day([leg]))} (21 days left)."
  end

  defp next_words("ideas_half", [leg]) do
    "if it doubles (#{money(leg.open_price * 2)}), half are sold, which pays back what all " <>
      "cost; the rest ride until #{day(manage_day([leg]))} (21 days left) or until they fall " <>
      "back to #{money(leg.open_price)}. Before that, all are sold if it halves " <>
      "(#{money(leg.open_price / 2)})."
  end

  defp next_words("crash_puts", [leg]) do
    "held whatever happens until #{day(manage_day([leg]))} (21 days left), then sold and " <>
      "next month's put bought."
  end

  defp next_words("crash_puts_half", [leg]) do
    "if it doubles (#{money(leg.open_price * 2)}), half are sold, which pays back what all " <>
      "cost. Whatever is left is sold on #{day(manage_day([leg]))} (21 days left) and next " <>
      "month's bought; after the double, sooner if it falls back to #{money(leg.open_price)}."
  end

  defp next_words(_book, legs),
    do: "the book's rules close it by #{day(manage_day(legs))} (21 days left) at the latest."

  defp manage_day([leg | _]), do: Date.add(leg.expiration, -21)

  defp copy_words(legs) do
    how =
      if length(legs) > 1,
        do: "enter the legs together as one multi-leg order at that net price or better",
        else: "enter it as a limit order at that price or better"

    account = account_words(legs)

    "Nothing; the paper book handles it. To copy it on Wealthsimple, #{how}; prices have moved " <>
      "since 10:00, so skip it if it won't fill by the close.#{account}"
  end

  # Where Wealthsimple allows the trade: long options, secured puts and
  # covered calls in a TFSA; every spread only in a margin account.
  defp account_words([%{side: "short", kind: "put"} = leg]),
    do:
      " A TFSA works: Wealthsimple allows secured puts there, with " <>
        "#{money(leg.strike * Pick.multiplier() * leg.quantity)} US set aside to buy the shares."

  defp account_words([_leg]), do: " A TFSA works."

  defp account_words(_legs),
    do:
      " Spreads need a Wealthsimple margin account with USD enabled; they aren't allowed in " <>
        "a TFSA or RRSP."
end
