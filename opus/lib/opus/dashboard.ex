defmodule Opus.Dashboard do
  @moduledoc """
  The dashboard's inputs: engine health, circuit-breaker suspensions,
  failed jobs, pipeline tests stopped part-way, the paper options books,
  live closes, the ideas scan and this month's index exposure, shaped for
  `Opus.Dashboard.Alerts` and the page's tiles.

  Broker balances are not gathered here: they are slow, so the page loads
  them after it connects (`accounts/0`) and adds any offline broker to the
  alerts then.
  """

  import Ecto.Query

  alias Opus.Accounts.Snapshots
  alias Opus.Accounts
  alias Opus.Accounts.IndexExposure
  alias Opus.Auro.Client
  alias Opus.Dashboard.Alerts
  alias Opus.Journal.TradeStory
  alias Opus.Options
  alias Opus.Options.Paper
  alias Opus.Trading.{AccountPause, DriftCheck}
  alias Opus.Options.Paper.{Legs, Wheel}
  alias Opus.Pipeline.Stuck
  alias Opus.Repo
  alias Opus.Trading.Strategies

  require Logger

  @day_seconds 86_400

  # What the alert calls each part of the gather when it fails.
  @section_names %{
    health: "engine health",
    books: "paper options books",
    ideas: "options ideas",
    exposure: "index exposure",
    live_open: "open live trades",
    suspensions: "circuit-breaker suspensions",
    drift: "live vs backtest checks",
    account_pause: "drawdown pause",
    failed_jobs: "failed jobs",
    live_closes: "live trades closed today",
    nav_age: "account numbers",
    paper: "open paper trades",
    paper_events: "paper book events",
    book_tiles: "paper book tiles",
    live: "live trading tile",
    stuck_runs: "stopped strategy tests",
    holdings: "holdings history"
  }

  @no_live %{engine_up: false, open_trades: 0, nav: nil, nav_change: nil}

  @doc """
  Everything but the broker balances: `:input` for the alert rules and the
  data for the tiles.

  Each part is read on its own (`section/4`): one that raises is logged,
  shown empty and named in an alert, so the others (the safety alerts above
  all) still go out.
  """
  @spec gather(DateTime.t()) :: map()
  def gather(now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)

    {s, failed} =
      {%{}, []}
      |> section(:health, {:error, :unread}, &Client.get_live_health/0)
      |> section(:books, [], fn -> Enum.map(Paper.books(), &{&1, Paper.book(&1)}) end)
      |> section(:ideas, {nil, []}, &Options.latest_ideas/0)
      |> section(:exposure, nil, fn -> IndexExposure.current(today) end)
      |> section(:live_open, [], &live_positions/0)
      |> section(:suspensions, [], &suspensions/0)
      |> section(:drift, [], &drift/0)
      |> section(:account_pause, nil, &account_pause/0)
      |> section(:failed_jobs, [], fn -> failed_jobs(now) end)
      |> section(:live_closes, [], fn -> live_closes(now) end)
      |> section(:nav_age, nil, fn -> nav_age(now) end)
      |> section(:stuck_runs, [], &Stuck.list/0)
      |> section(:holdings, nil, fn -> Snapshots.history(30) |> Snapshots.summary() end)

    {s, failed} =
      {s, failed}
      |> section(:paper, [], fn -> Enum.flat_map(s.books, &paper_trades/1) end)
      |> section(:paper_events, [], fn -> paper_events(s.books) end)
      |> section(:book_tiles, [], fn -> Enum.map(s.books, &book_tile/1) end)
      |> section(:live, @no_live, fn -> live(s.health) end)

    {scanned_on, ideas} = s.ideas

    input = %{
      now: now,
      today: today,
      engine: if(:health in failed, do: :unknown, else: engine(s.health)),
      candle_age: candle_age(s.health),
      untracked_trades: untracked_trades(s.health),
      hedging: hedging(s.health),
      nav_age: s.nav_age,
      suspensions: s.suspensions,
      drift: s.drift,
      account_pause: s.account_pause,
      failed_jobs: s.failed_jobs,
      stuck_runs: s.stuck_runs,
      failed_sections: failed |> Enum.reverse() |> Enum.map(&Map.fetch!(@section_names, &1)),
      offline_brokers: [],
      exposure: s.exposure,
      paper: s.paper,
      paper_events: s.paper_events,
      live_opens: Enum.filter(s.live_open, &opened_since?(&1, now)),
      live_closes: s.live_closes,
      ideas: scanned_on && %{count: length(ideas), scanned_on: scanned_on},
      holdings: s.holdings
    }

    %{
      input: input,
      live: s.live,
      books: s.book_tiles,
      positions: s.live_open ++ input.paper,
      exposure: s.exposure
    }
  end

  @doc """
  Runs one part of the gather, adding its value under `name` to the
  accumulated `{values, failed}`. A part that raises or exits is logged
  with its name and stands in as `default`, and its name joins `failed`.
  """
  @spec section({map(), [atom()]}, atom(), term(), (-> term())) :: {map(), [atom()]}
  def section({values, failed}, name, default, fun) do
    {Map.put(values, name, fun.()), failed}
  rescue
    e ->
      Logger.error("[Dashboard] #{name} failed: " <> Exception.format(:error, e, __STACKTRACE__))
      {Map.put(values, name, default), [name | failed]}
  catch
    :exit, reason ->
      Logger.error("[Dashboard] #{name} exited: #{inspect(reason)}")
      {Map.put(values, name, default), [name | failed]}
  end

  @doc "The alerts for gathered inputs, with any offline brokers added."
  @spec alerts(map(), [map()]) :: [Alerts.alert()]
  def alerts(input, offline_brokers \\ []),
    do: Alerts.build(%{input | offline_brokers: offline_brokers})

  # The last good accounts overview, kept between visits so the Accounts
  # tile shows a total at once instead of "asking the brokers…" every time.
  # Written at most every few minutes, so :persistent_term's cost on update
  # doesn't matter, and it needs no process to own it.
  @accounts_key {__MODULE__, :accounts}
  @accounts_fresh_seconds 300

  @doc """
  The accounts overview for the Accounts tile. Slow: the brokers are called.
  A good answer is cached for `cached_accounts/0`.
  """
  @spec accounts() :: {:ok, map()} | {:error, term()}
  def accounts do
    with {:ok, overview} <- Accounts.overview() do
      :persistent_term.put(@accounts_key, {overview, DateTime.utc_now()})
      {:ok, overview}
    end
  end

  @doc "The last good accounts overview and when it was fetched, or nil."
  @spec cached_accounts() :: {map(), DateTime.t()} | nil
  def cached_accounts, do: :persistent_term.get(@accounts_key, nil)

  @doc """
  Whether a cached overview is recent enough not to ask the brokers again.
  One with a broker offline never is: the broker may be back (a fresh
  Questrade token and a restart), and the tile shouldn't keep saying it's down.
  """
  @spec fresh?({map(), DateTime.t()} | nil) :: boolean()
  def fresh?({%{offline: [_ | _]}, _at}), do: false
  def fresh?({_overview, at}), do: DateTime.diff(DateTime.utc_now(), at) < @accounts_fresh_seconds
  def fresh?(nil), do: false

  defp engine({:ok, _health}), do: :up
  defp engine({:error, reason}), do: {:down, Client.describe_error(reason)}

  defp candle_age({:ok, %{"last_candle_persisted_seconds_ago" => age}}) when is_integer(age),
    do: age

  defp candle_age(_health), do: nil

  # Trades open at OANDA the engine isn't tracking. An older engine doesn't
  # report them: nothing to say.
  defp untracked_trades({:ok, %{"untracked_trades" => trades}}) when is_list(trades) do
    for %{"id" => id} = t <- trades,
        do: %{id: to_string(id), instrument: t["instrument"], units: t["units"]}
  end

  defp untracked_trades(_health), do: []

  # Whether the OANDA account allows opposite trades on one instrument; nil
  # when the engine doesn't say.
  defp hedging({:ok, %{"hedging_enabled" => hedging}}) when is_boolean(hedging), do: hedging
  defp hedging(_health), do: nil

  defp account_pause do
    case AccountPause.open() do
      nil ->
        nil

      p ->
        %{
          down: AccountPause.drawdown(p.peak_nav, p.nav),
          peak: p.peak_nav,
          nav: p.nav,
          limit: p.limit_pct
        }
    end
  end

  # Switched-on strategies whose latest check says they aren't behaving
  # like their backtest.
  defp drift do
    rows = Enum.filter(Strategies.list(), & &1.enabled)
    checks = DriftCheck.latest(Enum.map(rows, & &1.id))

    for row <- rows, %{verdict: "off"} = check <- [checks[row.id]] do
      %{
        id: row.id,
        name: row.name,
        instrument: row.instrument,
        detail: check.findings |> Enum.find(&(&1["verdict"] == "off")) |> Map.fetch!("words")
      }
    end
  end

  defp suspensions do
    for %{suspension: %{} = s} = row <- Strategies.list() do
      %{id: row.id, name: row.name, detail: s.trigger_detail}
    end
  end

  @doc """
  Clear a job's failures from the dashboard: marks its discarded runs from
  the last day as cleared (`cleared_at` in the job's meta), so the alerts
  skip them while the runs and their errors stay in Oban's history until
  the pruner removes them. A run still retrying stays until it succeeds or
  gives up. Returns how many were cleared.
  """
  @spec clear_failed_jobs(String.t(), DateTime.t()) :: non_neg_integer()
  def clear_failed_jobs(worker, now \\ DateTime.utc_now()) do
    since = now |> DateTime.add(-@day_seconds) |> DateTime.to_naive()
    cleared_at = DateTime.to_iso8601(now)

    {count, _} =
      from(j in "oban_jobs",
        where:
          j.worker == ^worker and j.state == "discarded" and j.attempted_at >= ^since and
            fragment("(? ->> 'cleared_at') IS NULL", j.meta),
        update: [
          set: [
            meta: fragment("? || jsonb_build_object('cleared_at', ?::text)", j.meta, ^cleared_at)
          ]
        ]
      )
      |> Repo.update_all([])

    count
  end

  # Jobs discarded, or retrying after an error, in the last day, less the
  # ones cleared from the dashboard.
  defp failed_jobs(now) do
    since = now |> DateTime.add(-@day_seconds) |> DateTime.to_naive()

    from(j in "oban_jobs",
      where:
        j.state in ["discarded", "retryable"] and j.attempted_at >= ^since and
          fragment("(? ->> 'cleared_at') IS NULL", j.meta),
      order_by: [desc: j.attempted_at],
      select: %{worker: j.worker, errors: j.errors}
    )
    |> Repo.all()
    |> Enum.map(&%{worker: &1.worker, error: last_error(&1.errors)})
  end

  defp last_error([_ | _] = errors) do
    errors
    |> List.last()
    |> Map.get("error", "")
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  defp last_error(_errors), do: nil

  defp live_closes(now) do
    since = DateTime.add(now, -@day_seconds)

    from(t in "live_trades",
      where: t.status == "closed" and t.exit_time >= ^since,
      order_by: [desc: t.exit_time],
      select: %{
        id: type(t.id, Ecto.UUID),
        instrument: t.instrument,
        direction: t.direction,
        status: t.status,
        units: t.units,
        entry_price: t.entry_price,
        exit_price: t.exit_price,
        entry_time: type(t.entry_time, :utc_datetime_usec),
        exit_time: type(t.exit_time, :utc_datetime_usec),
        exit_reason: t.exit_reason,
        pnl: t.pnl,
        pnl_percent: t.pnl_percent
      }
    )
    |> Repo.all()
  end

  # Each open paper trade, reduced to what the rules look at: its short
  # and long legs' strikes, the underlying's latest spot, its dates, its
  # most possible loss and how close it is to its take-profit (marked at
  # the mid).
  defp paper_trades({"wheel", book}) do
    marks = Map.new(book.legs, &{&1.position.id, &1.mark})

    for %{short: %{} = short} = trade <- book.trades do
      mark = marks[short.id]

      %{
        book: "wheel",
        key: "wheel:#{short.id}",
        symbol: trade.symbol,
        label: "#{trade.symbol} #{money(short.strike)} #{short.kind} (wheel)",
        link: link("wheel", trade.symbol),
        spot: trade.spot,
        expiration: short.expiration,
        manage_on: Wheel.manage_on(short),
        shorts: [short],
        longs: [],
        max_loss: nil,
        take_profit: mark && %{close_cost: mark, target: Wheel.take_profit_price(short)},
        pnl: trade.pnl,
        opened_on: short.opened_on
      }
    end
  end

  defp paper_trades({book_key, book}) do
    for %{status: "open"} = trade <- book.trades do
      open = Enum.filter(trade.legs, &(&1.status == "open"))
      {shorts, longs} = Enum.split_with(open, &(&1.side == "short"))

      %{
        book: book_key,
        key: "#{book_key}:#{trade.id}",
        symbol: trade.symbol,
        label: label(book_key, trade.symbol, shorts, longs),
        link: link(book_key, trade.id),
        spot: trade.spot,
        expiration: trade.expiration,
        manage_on: trade.expiration && Date.add(trade.expiration, -21),
        shorts: shorts,
        longs: longs,
        max_loss: trade.summary.max_loss,
        take_profit: take_profit(book_key, open, trade.marks),
        pnl: trade.pnl,
        opened_on: trade.opened_on
      }
    end
  end

  defp take_profit(book, legs, marks) when book in ~w(put_spread iron_condor) do
    if Enum.all?(legs, &is_number(marks[&1.id])) do
      %{
        close_cost: Enum.sum_by(legs, &(Legs.sign(&1) * marks[&1.id] * &1.quantity)),
        target: Legs.net_premium(legs) * 0.5
      }
    end
  end

  defp take_profit("ideas", [leg], marks),
    do: is_number(marks[leg.id]) && %{mark: marks[leg.id], target: leg.open_price * 2}

  # A half-at-double book until it has sold its half.
  defp take_profit(book, [%{quantity: contracts} = leg], marks)
       when book in ~w(ideas_half crash_puts_half) and contracts > 1,
       do:
         is_number(marks[leg.id]) &&
           %{mark: marks[leg.id], target: leg.open_price * 2, half: true}

  defp take_profit(_book, _legs, _marks), do: nil

  defp label("put_spread", symbol, [short], [long]),
    do: "#{symbol} put spread #{strike(short.strike)}/#{strike(long.strike)}"

  defp label("iron_condor", symbol, shorts, longs) do
    strikes =
      (shorts ++ longs) |> Enum.map(& &1.strike) |> Enum.sort() |> Enum.map_join("/", &strike/1)

    "#{symbol} iron condor #{strikes}"
  end

  defp label(book, symbol, _shorts, [leg | _]) when book in ~w(crash_puts crash_puts_half),
    do: "#{symbol} #{money(leg.strike)} crash put"

  defp label(_book, symbol, _shorts, [%{kind: kind} = leg | _]),
    do: "#{symbol} #{money(leg.strike)} #{kind}"

  defp label(book, symbol, _shorts, _longs), do: "#{symbol} #{book}"

  # What happened on the latest market date any book recorded: one row per
  # closed trade with its P&L (a spread's legs close together), the wheel's
  # single-leg closes, expiries, assignments and call-aways with their cash,
  # every half sold at double, and every trade opened, with its legs so it
  # can be copied by hand.
  defp paper_events(books) do
    latest =
      books
      |> Enum.flat_map(fn {_book, data} -> Enum.map(data.events, & &1.on) end)
      |> Enum.max(Date, fn -> nil end)

    if latest,
      do: Enum.flat_map(books, &(finished(&1, latest) ++ opened(&1, latest))),
      else: []
  end

  defp opened({"wheel", %{trades: trades}}, on) do
    for t <- trades, %{opened_on: ^on, kind: kind} = leg <- t.legs, kind in ~w(put call) do
      %{
        book: "wheel",
        key: "wheel:#{leg.id}:open",
        symbol: t.symbol,
        kind: "open",
        on: on,
        label: leg_label(leg, t.symbol),
        spot: t.spot,
        legs: [leg],
        link: link("wheel", t.symbol)
      }
    end
  end

  defp opened({book, %{trades: trades}}, on) do
    for %{opened_on: ^on} = t <- trades do
      {shorts, longs} = Enum.split_with(t.legs, &(&1.side == "short"))

      %{
        book: book,
        key: "#{book}:#{t.id}:open",
        symbol: t.symbol,
        kind: "open",
        on: on,
        label: label(book, t.symbol, shorts, longs),
        spot: t.spot,
        legs: t.legs,
        link: link(book, t.id)
      }
    end
  end

  defp finished({"wheel", %{events: events, trades: trades}}, on) do
    legs = for t <- trades, leg <- t.legs, into: %{}, do: {leg.id, leg}

    for %{on: ^on, kind: kind} = e <- events, kind in ~w(close expire assign call_away) do
      Map.merge(e, %{
        book: "wheel",
        key: "wheel:event:#{e.id}",
        label: leg_label(legs[e.position_id], e.symbol),
        pnl: nil,
        link: link("wheel", e.symbol)
      })
    end
  end

  defp finished({book, %{trades: trades}}, on) do
    closed(book, trades, on) ++ halves_sold(book, trades, on)
  end

  defp closed(book, trades, on) do
    for %{closed_on: ^on} = t <- trades do
      {shorts, longs} = Enum.split_with(t.legs, &(&1.side == "short"))

      %{
        book: book,
        key: "#{book}:#{t.id}:close",
        symbol: t.symbol,
        kind: if(Enum.all?(t.legs, &(&1.status == "expired")), do: "expire", else: "close"),
        on: on,
        label: label(book, t.symbol, shorts, longs),
        cash: nil,
        pnl: t.pnl,
        link: link(book, t.id)
      }
    end
  end

  # The half a half-at-double book sold at double: a closed leg in a trade
  # still open.
  defp halves_sold(book, trades, on) do
    for %{status: "open"} = t <- trades,
        %{status: "closed", closed_on: ^on} = sold <- t.legs,
        kept <- Enum.filter(t.legs, &(&1.status == "open")) do
      {shorts, longs} = Enum.split_with(t.legs, &(&1.side == "short"))

      %{
        book: book,
        key: "#{book}:#{t.id}:half",
        symbol: t.symbol,
        kind: "half",
        on: on,
        label: label(book, t.symbol, shorts, longs),
        sold: sold,
        kept: kept,
        manage_on: Date.add(kept.expiration, -21),
        link: link(book, t.id)
      }
    end
  end

  defp leg_label(%{kind: "shares", quantity: n}, symbol), do: "#{n} #{symbol} shares"
  defp leg_label(%{kind: kind, strike: strike}, symbol), do: "#{symbol} #{money(strike)} #{kind}"
  defp leg_label(nil, symbol), do: symbol

  # Open live trades, as rows beside the paper trades in the open positions.
  defp live_positions do
    from(t in "live_trades",
      where: t.status == "open",
      order_by: [desc: t.entry_time],
      select: %{
        id: type(t.id, Ecto.UUID),
        instrument: t.instrument,
        direction: t.direction,
        units: t.units,
        entry_price: t.entry_price,
        stop_loss_price: t.stop_loss_price,
        entry_time: type(t.entry_time, :utc_datetime_usec)
      }
    )
    |> Repo.all()
    |> Enum.map(fn t ->
      %{
        id: t.id,
        book: "live",
        label: "#{TradeStory.market(t)} #{String.downcase(t.direction)}",
        direction: t.direction,
        units: t.units,
        link: "/journal?trade=#{t.id}",
        pnl: nil,
        opened_on: t.entry_time && Opus.Clock.date(t.entry_time),
        entry_time: t.entry_time,
        entry_price: t.entry_price,
        stop_loss_price: t.stop_loss_price
      }
    end)
  end

  defp opened_since?(%{entry_time: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) < @day_seconds

  defp opened_since?(_trade, _now), do: false

  defp link(book, nil), do: "/options?view=paper&book=#{book}"
  defp link(book, trade), do: "/options?view=paper&book=#{book}&trade=#{trade}"

  defp book_tile({book, data}) do
    open =
      if book == "wheel",
        do: Enum.count(data.trades, &(&1.short || &1.shares)),
        else: Enum.count(data.trades, &(&1.status == "open"))

    %{
      book: book,
      value: data.value,
      pnl: data.pnl,
      return: data.return,
      open: open,
      started: data.started_on != nil,
      link: link(book, nil)
    }
  end

  defp live(health) do
    nav = latest_nav()

    %{
      engine_up: match?({:ok, _}, health),
      open_trades: Repo.one(from(t in "live_trades", where: t.status == "open", select: count())),
      nav: nav,
      nav_change: nav && nav - (first_nav_today() || nav)
    }
  end

  # Seconds since the engine last stored the account's numbers, or nil
  # before it ever has.
  defp nav_age(now) do
    from(s in "account_snapshots",
      order_by: [desc: s.timestamp],
      limit: 1,
      select: type(s.timestamp, :utc_datetime_usec)
    )
    |> Repo.one()
    |> then(&(&1 && DateTime.diff(now, &1)))
  end

  defp latest_nav do
    from(s in "account_snapshots", order_by: [desc: s.timestamp], limit: 1, select: s.nav)
    |> Repo.one()
  end

  defp first_nav_today do
    # Today starts at midnight New York, like every other "today" on the page.
    midnight = Opus.Clock.midnight(Opus.Clock.today())

    from(s in "account_snapshots",
      where: s.timestamp >= ^midnight,
      order_by: [asc: s.timestamp],
      limit: 1,
      select: s.nav
    )
    |> Repo.one()
  end

  defp money(value), do: OpusWeb.Format.money(value)
  defp strike(value), do: OpusWeb.Format.strike(value)
end
