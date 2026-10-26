defmodule Opus.Dashboard do
  @moduledoc """
  The dashboard's inputs: engine health, circuit-breaker suspensions,
  failed jobs, the paper options books, live closes, the ideas scan and
  this month's index exposure, shaped for `Opus.Dashboard.Alerts` and the
  page's tiles.

  Broker balances are not gathered here: they are slow, so the page loads
  them after it connects (`accounts/0`) and adds any offline broker to the
  alerts then.
  """

  import Ecto.Query

  alias Opus.Accounts
  alias Opus.Accounts.IndexExposure
  alias Opus.Auro.Client
  alias Opus.Dashboard.Alerts
  alias Opus.Options
  alias Opus.Options.Paper
  alias Opus.Options.Paper.{Legs, Wheel}
  alias Opus.Repo
  alias Opus.Trading.Strategies

  @day_seconds 86_400

  @book_names %{
    "wheel" => {"Wheel", "Theta gang"},
    "put_spread" => {"Put spreads", "Defined-risk degen"},
    "iron_condor" => {"Iron condors", "Iron condor (theta + prayer)"},
    "ideas" => {"Ideas", "Dip YOLO calls"},
    "crash_puts" => {"Crash puts", "Doomsday insurance"}
  }

  @doc """
  Everything but the broker balances: `:input` for the alert rules and the
  data for the tiles.
  """
  @spec gather(DateTime.t()) :: map()
  def gather(now \\ DateTime.utc_now()) do
    health = Client.get_live_health()
    books = Enum.map(Paper.books(), &{&1, Paper.book(&1)})
    {scanned_on, ideas} = Options.latest_ideas()
    exposure = IndexExposure.current(DateTime.to_date(now))

    input = %{
      now: now,
      today: DateTime.to_date(now),
      engine: engine(health),
      candle_age: candle_age(health),
      suspensions: suspensions(),
      failed_jobs: failed_jobs(now),
      offline_brokers: [],
      exposure: exposure,
      paper: Enum.flat_map(books, &paper_trades/1),
      paper_events: paper_events(books),
      live_closes: live_closes(now),
      ideas: scanned_on && %{count: length(ideas), scanned_on: scanned_on}
    }

    %{
      input: input,
      live: live(health),
      books: Enum.map(books, &book_tile/1),
      exposure: exposure
    }
  end

  @doc "The alerts for gathered inputs, with any offline brokers added."
  @spec alerts(map(), [map()]) :: [Alerts.alert()]
  def alerts(input, offline_brokers \\ []),
    do: Alerts.build(%{input | offline_brokers: offline_brokers})

  @doc "The accounts overview for the Accounts tile (slow: brokers are called)."
  @spec accounts() :: {:ok, map()} | {:error, term()}
  def accounts, do: Accounts.overview()

  @doc "Display names for a book, serious and WSB."
  @spec book_name(String.t()) :: {String.t(), String.t()}
  def book_name(book), do: Map.get(@book_names, book, {book, book})

  defp engine({:ok, _health}), do: :up
  defp engine({:error, reason}), do: {:down, Client.describe_error(reason)}

  defp candle_age({:ok, %{"last_candle_persisted_seconds_ago" => age}}) when is_integer(age),
    do: age

  defp candle_age(_health), do: nil

  defp suspensions do
    for %{suspension: %{} = s} = row <- Strategies.list() do
      %{id: row.id, name: row.name, detail: s.trigger_detail}
    end
  end

  # Jobs discarded, or retrying after an error, in the last day.
  defp failed_jobs(now) do
    since = now |> DateTime.add(-@day_seconds) |> DateTime.to_naive()

    from(j in "oban_jobs",
      where: j.state in ["discarded", "retryable"] and j.attempted_at >= ^since,
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
        instrument: t.instrument,
        direction: t.direction,
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
        symbol: trade.symbol,
        label: "#{trade.symbol} #{money(short.strike)} #{short.kind} (wheel)",
        link: link("wheel", trade.symbol),
        spot: trade.spot,
        expiration: short.expiration,
        manage_on: Wheel.manage_on(short),
        shorts: [short],
        longs: [],
        max_loss: nil,
        take_profit: mark && %{close_cost: mark, target: Wheel.take_profit_price(short)}
      }
    end
  end

  defp paper_trades({book_key, book}) do
    for %{status: "open"} = trade <- book.trades do
      open = Enum.filter(trade.legs, &(&1.status == "open"))
      {shorts, longs} = Enum.split_with(open, &(&1.side == "short"))

      %{
        book: book_key,
        symbol: trade.symbol,
        label: label(book_key, trade.symbol, shorts, longs),
        link: link(book_key, trade.id),
        spot: trade.spot,
        expiration: trade.expiration,
        manage_on: trade.expiration && Date.add(trade.expiration, -21),
        shorts: shorts,
        longs: longs,
        max_loss: trade.summary.max_loss,
        take_profit: take_profit(book_key, open, trade.marks)
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

  defp take_profit(_book, _legs, _marks), do: nil

  defp label("put_spread", symbol, [short], [long]),
    do: "#{symbol} put spread #{num(short.strike)}/#{num(long.strike)}"

  defp label("iron_condor", symbol, _shorts, _longs), do: "#{symbol} iron condor"

  defp label("crash_puts", symbol, _shorts, [leg | _]),
    do: "#{symbol} #{money(leg.strike)} crash put"

  defp label(_book, symbol, _shorts, [%{kind: kind} = leg | _]),
    do: "#{symbol} #{money(leg.strike)} #{kind}"

  defp label(book, symbol, _shorts, _longs), do: "#{symbol} #{book}"

  # The books' events on the latest market date any of them recorded.
  defp paper_events(books) do
    events =
      for {book, %{events: events, trades: trades}} <- books, event <- events do
        Map.merge(event, %{book: book, link: event_link(book, event, trades)})
      end

    case events |> Enum.map(& &1.on) |> Enum.max(Date, fn -> nil end) do
      nil -> []
      latest -> Enum.filter(events, &(&1.on == latest))
    end
  end

  defp event_link("wheel", event, _trades), do: link("wheel", event.symbol)

  defp event_link(book, event, trades) do
    case Enum.find(trades, fn t -> Enum.any?(t.legs, &(&1.id == event.position_id)) end) do
      nil -> link(book, nil)
      trade -> link(book, trade.id)
    end
  end

  defp link(book, nil), do: "/options?view=paper&book=#{book}"
  defp link(book, trade), do: "/options?view=paper&book=#{book}&trade=#{trade}"

  defp book_tile({book, data}) do
    open =
      if book == "wheel",
        do: Enum.count(data.trades, &(&1.short || &1.shares)),
        else: Enum.count(data.trades, &(&1.status == "open"))

    {name, wsb} = book_name(book)

    %{
      book: book,
      name: name,
      wsb: wsb,
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

  defp latest_nav do
    from(s in "account_snapshots", order_by: [desc: s.timestamp], limit: 1, select: s.nav)
    |> Repo.one()
  end

  defp first_nav_today do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00])

    from(s in "account_snapshots",
      where: s.timestamp >= ^midnight,
      order_by: [asc: s.timestamp],
      limit: 1,
      select: s.nav
    )
    |> Repo.one()
  end

  defp money(value), do: OpusWeb.Format.money(value)
  defp num(value), do: OpusWeb.Format.num(value)
end
