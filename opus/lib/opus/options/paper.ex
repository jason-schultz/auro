defmodule Opus.Options.Paper do
  @moduledoc """
  The options paper books (research/options_paper_engine.md). Once a market day,
  on each underlying's latest stored chain, every book runs its rules: the
  wheel (`Opus.Options.Paper.Wheel`), the put credit spread and iron condor
  (`Opus.Options.Paper.Structures`), and the ideas calls and crash puts,
  each also in a "half at double" book (`Opus.Options.Paper.LongOptions`).
  The books are read back for the
  Options page. Places no orders.

  Each book is its own paper account: its cash is the starting cash plus
  its events' cash. Open wheel puts reserve their strike × 100, spreads and
  condors their maximum loss. A snapshot's market date is its New York date
  at capture. A market date already recorded for a book and underlying is
  never run again. A leg still open at expiry settles on the first run after
  expiry day, against that day's close from the underlying's daily bars; it
  waits while the bar isn't stored.

  During the session (`take_profits/1`, every 15 minutes) each take-profit
  works like a resting order at the broker: once that day's check has run,
  a fresh quote that reaches it fills it then. Entries, the 21-day closes,
  rolls and stops stay with the once-a-day check. Open legs are priced at
  their latest quote, so the books show intraday P&L.
  """

  import Ecto.Query

  require Logger

  alias Opus.Options
  alias Opus.Options.Idea
  alias Opus.Options.Paper.{Event, Legs, LongOptions, Position, Structures, Trade, Wheel}
  alias Opus.{Clock, Repo}

  @recent_events 12
  @open ~T[09:30:00]

  defp config, do: Application.fetch_env!(:opus, __MODULE__)

  @doc "The books, in the order the page shows them."
  @spec books() :: [String.t()]
  def books, do: Trade.strategies()

  @doc "The underlyings a book trades: configured, or every stored chain for ideas."
  @spec underlyings(String.t()) :: [String.t()]
  def underlyings(book) when book in ~w(ideas ideas_half),
    do: Enum.map(Options.underlyings(), & &1.symbol)

  def underlyings(book), do: Map.fetch!(config()[:books], book)

  @doc """
  Run today's rules for every book on each of its underlyings. Each book and
  underlying runs on its own: one that raises is logged and returned as
  `{:error, exception}`, and the rest still run.
  """
  @spec run() :: [
          {String.t(), String.t(), {:ok, [tuple()]} | {:skipped, atom()} | {:error, term()}}
        ]
  def run do
    for book <- books(), symbol <- underlyings(book) do
      {book, symbol, isolated("#{book} #{symbol}", fn -> run(book, symbol) end)}
    end
  end

  @doc """
  Run one book on one underlying's latest snapshot, once per market date.
  A snapshot captured before the 09:30 New York open (the pre-open capture,
  holding the previous session's closing quotes) is not traded on: the day
  is skipped for that book and underlying.
  """
  @spec run(String.t(), String.t()) :: {:ok, [tuple()]} | {:skipped, atom()}
  def run(book, symbol) do
    case Options.snapshot(symbol) do
      [] ->
        {:skipped, :no_snapshot}

      [%{instrument_id: id, captured_at: captured_at} | _] = rows ->
        as_of = market_date(captured_at)

        cond do
          not in_session?(captured_at) ->
            Logger.warning(
              "[PaperBook] #{book} #{symbol}: latest chain was captured before the open " <>
                "(#{captured_at} UTC); not trading on it today"
            )

            {:skipped, :stale_snapshot}

          ran?(book, id, as_of) ->
            {:skipped, :already_ran}

          true ->
            Repo.transaction(fn -> step(book, id, as_of, rows) end)
        end
    end
  end

  # Captured at or after 09:30 New York on its own date: live quotes, not
  # the previous session's close.
  defp in_session?(captured_at),
    do: Time.compare(DateTime.to_time(Clock.local(captured_at)), @open) != :lt

  # Runs one book on one underlying, so a raise in one doesn't stop the rest.
  defp isolated(name, fun) do
    fun.()
  rescue
    e ->
      Logger.error("[PaperBook] #{name} failed: " <> Exception.format(:error, e, __STACKTRACE__))
      {:error, e}
  end

  @doc "Run the wheel on one underlying."
  @spec run_underlying(String.t()) :: {:ok, [Wheel.action()]} | {:skipped, atom()}
  def run_underlying(symbol), do: run("wheel", symbol)

  @doc "Every open option leg's contract across the books, by underlying symbol."
  @spec open_contracts() :: %{String.t() => [integer()]}
  def open_contracts do
    from(p in Position,
      join: i in "instruments",
      on: i.id == p.underlying_instrument_id,
      where: p.status == "open" and p.kind in ~w(put call),
      distinct: true,
      select: {i.symbol, p.contract_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Fill the take-profits that today's quotes reach, as resting orders would:
  every open trade in every book, on the latest quote captured since New
  York midnight, once that book's check has run on the underlying today
  (the check is when the orders are placed). Returns each book and
  underlying with the fills made.
  """
  @spec take_profits(DateTime.t()) :: [{String.t(), integer(), [tuple()]}]
  def take_profits(now \\ DateTime.utc_now()) do
    as_of = Clock.date(now)
    commission = config()[:commission]

    from(t in Trade, where: t.status == "open", select: {t.strategy, t.underlying_instrument_id})
    |> distinct(true)
    |> Repo.all()
    |> Enum.filter(fn {book, id} -> ran?(book, id, as_of) end)
    |> Enum.map(fn {book, id} ->
      fills =
        case isolated("#{book} #{id} take-profits", fn ->
               Repo.transaction(fn -> take_profits(book, id, as_of, commission) end)
             end) do
          {:ok, fills} -> fills
          {:error, _reason} -> []
        end

      {book, id, fills}
    end)
    |> Enum.reject(&match?({_book, _id, []}, &1))
  end

  defp take_profits("wheel", id, as_of, commission) do
    open = open_positions("wheel", id)
    lot = Enum.find(open, &(&1.kind == "shares"))
    legs = Enum.filter(open, &(&1.kind in ~w(put call)))
    quotes = latest_quotes(Enum.map(legs, & &1.contract_id), Clock.midnight(as_of))

    for leg <- legs,
        quote = quotes[leg.contract_id],
        {:close, _leg, _price} = fill <- [Wheel.take_profit(leg, quote)] do
      apply_wheel(fill, id, as_of, lot, %{spot: quote.spot}, commission)
      fill
    end
  end

  defp take_profits(book, id, as_of, commission) do
    trades = open_trades(book, id)
    ids = for t <- trades, leg <- t.legs, do: leg.contract_id
    quotes = latest_quotes(ids, Clock.midnight(as_of))

    for trade <- trades,
        fill = trade_take_profit(book, trade, quotes),
        not match?({:hold, _trade}, fill) do
      spot = quotes |> Map.values() |> Enum.max_by(& &1.captured_at) |> Map.fetch!(:spot)
      apply_trade(fill, book, id, as_of, %{spot: spot}, commission)
      fill
    end
  end

  defp trade_take_profit(book, trade, quotes) when book in ~w(put_spread iron_condor),
    do: Structures.take_profit(trade, quotes)

  defp trade_take_profit(book, trade, quotes), do: LongOptions.take_profit(book, trade, quotes)

  # Each contract's latest quote captured at or after `since`.
  defp latest_quotes([], _since), do: %{}

  defp latest_quotes(contract_ids, since) do
    from(q in "option_quotes",
      where:
        q.contract_id in type(^contract_ids, {:array, :integer}) and
          q.captured_at >= type(^since, :utc_datetime_usec),
      distinct: q.contract_id,
      order_by: [asc: q.contract_id, desc: q.captured_at],
      select:
        {q.contract_id,
         %{
           bid: q.bid,
           ask: q.ask,
           spot: q.spot,
           captured_at: type(q.captured_at, :naive_datetime_usec)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @spec market_date(NaiveDateTime.t()) :: Date.t()
  def market_date(captured_at),
    do: Clock.date(captured_at)

  defp ran?(book, id, as_of),
    do:
      Repo.exists?(
        from(e in Event,
          where: e.strategy == ^book and e.underlying_instrument_id == ^id and e.on == ^as_of
        )
      )

  defp step("wheel", id, as_of, rows) do
    commission = config()[:commission]
    open = open_positions("wheel", id)
    legs = Enum.filter(open, &(&1.kind in ~w(put call)))
    lot = Enum.find(open, &(&1.kind == "shares"))
    snapshot = snapshot(id, as_of, rows, legs)

    actions = Wheel.plan(%{legs: legs, shares: lot}, snapshot, available("wheel"), commission)
    Enum.each(actions, &apply_wheel(&1, id, as_of, lot, snapshot, commission))
    mark("wheel", id, as_of, snapshot)
    actions
  end

  defp step(book, id, as_of, rows) do
    commission = config()[:commission]
    trades = open_trades(book, id)
    snapshot = snapshot(id, as_of, rows, Enum.flat_map(trades, & &1.legs))
    available = available(book)

    actions =
      case book do
        ideas when ideas in ~w(ideas ideas_half) ->
          LongOptions.plan_ideas(
            book,
            trades,
            todays_ideas(id, as_of),
            snapshot,
            available,
            commission,
            open_count(book) - length(trades),
            held_contracts(book)
          )

        crash when crash in ~w(crash_puts crash_puts_half) ->
          LongOptions.plan_crash_puts(book, trades, snapshot, available, commission)

        structure ->
          Structures.plan(structure, List.first(trades), snapshot, available, commission)
      end

    Enum.each(actions, &apply_trade(&1, book, id, as_of, snapshot, commission))
    mark(book, id, as_of, snapshot)
    actions
  end

  defp snapshot(id, as_of, [%{spot: spot} | _] = rows, legs) do
    %{
      as_of: as_of,
      spot: spot,
      quotes: Map.new(rows, &{&1.contract_id, &1}),
      chain: Enum.map(rows, &Map.put(&1, :dte, Date.diff(&1.expiration, as_of))),
      expiry_spots: expiry_spots(id, legs, as_of)
    }
  end

  defp open_positions(book, id),
    do:
      Repo.all(
        from(p in Position,
          join: t in Trade,
          on: t.id == p.trade_id,
          where: t.strategy == ^book and p.underlying_instrument_id == ^id and p.status == "open",
          order_by: p.id
        )
      )

  defp open_trades(book, id) do
    book
    |> open_positions(id)
    |> Enum.group_by(& &1.trade_id)
    |> Enum.map(fn {trade_id, legs} -> %{id: trade_id, legs: legs} end)
    |> Enum.sort_by(& &1.id)
  end

  defp open_count(book),
    do:
      Repo.aggregate(from(t in Trade, where: t.strategy == ^book and t.status == "open"), :count)

  defp held_contracts(book) do
    from(p in Position,
      join: t in Trade,
      on: t.id == p.trade_id,
      where: t.strategy == ^book and not is_nil(p.contract_id),
      select: p.contract_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The scan from the snapshot's market date.
  defp todays_ideas(id, as_of),
    do:
      Repo.all(
        from(i in Idea, where: i.underlying_instrument_id == ^id and i.scanned_on == ^as_of)
      )

  # The closing price of each expiry day already past, from the underlying's
  # daily bars (stamped at New York midnight); one not stored yet is left out.
  defp expiry_spots(id, legs, as_of) do
    for expiration <- legs |> Enum.map(& &1.expiration) |> Enum.uniq(),
        Date.before?(expiration, as_of),
        close = daily_close(id, expiration),
        is_number(close),
        into: %{},
        do: {expiration, close}
  end

  defp daily_close(id, date) do
    from(c in "candles",
      where:
        c.instrument_id == ^id and c.granularity == "D" and c.complete and
          c.timestamp >= ^Clock.midnight(date) and
          c.timestamp < ^Clock.midnight(Date.add(date, 1)),
      select: c.close
    )
    |> Repo.one()
  end

  defp available(book), do: cash(book) - reserved(book)

  defp cash(book),
    do:
      config()[:starting_cash] +
        (Repo.one(from(e in Event, where: e.strategy == ^book, select: sum(e.cash))) || 0.0)

  defp reserved("wheel") do
    from(p in Position,
      join: t in Trade,
      on: t.id == p.trade_id,
      where: t.strategy == "wheel" and p.kind == "put" and p.status == "open",
      select: sum(p.strike * p.quantity)
    )
    |> Repo.one()
    |> Kernel.||(0.0)
    |> Kernel.*(Wheel.multiplier())
  end

  defp reserved(book) when book in ~w(put_spread iron_condor) do
    from(p in Position,
      join: t in Trade,
      on: t.id == p.trade_id,
      where: t.strategy == ^book and p.status == "open"
    )
    |> Repo.all()
    |> Enum.group_by(& &1.trade_id)
    |> Enum.sum_by(fn {_trade, legs} -> Structures.collateral(legs) end)
  end

  defp reserved(_book), do: 0.0

  # The wheel's actions, one leg at a time; each leg is its own trade.

  defp apply_wheel({:hold, _leg}, _id, _as_of, _lot, _snapshot, _commission), do: :ok

  defp apply_wheel({:open, contract} = action, id, as_of, _lot, snapshot, commission) do
    trade = open_trade("wheel", id, contract.kind, as_of)

    position =
      Repo.insert!(%Position{
        trade_id: trade.id,
        underlying_instrument_id: id,
        contract_id: contract.contract_id,
        kind: contract.kind,
        side: "short",
        quantity: 1,
        strike: contract.strike,
        expiration: contract.expiration,
        open_price: contract.bid,
        opened_on: as_of,
        commission: commission
      })

    event(position, "wheel", "open", as_of, Wheel.cash(action, commission), %{
      "spot" => snapshot.spot,
      "bid" => contract.bid,
      "ask" => contract.ask,
      "delta" => contract.delta,
      "dte" => contract.dte
    })
  end

  defp apply_wheel({:close, leg, price} = action, _id, as_of, _lot, snapshot, commission) do
    leg
    |> close(as_of, "closed", price, leg.commission + commission * leg.quantity)
    |> event("wheel", "close", as_of, Wheel.cash(action, commission), %{
      "spot" => snapshot.spot,
      "price" => price
    })
  end

  defp apply_wheel({:expire, leg} = action, _id, as_of, _lot, snapshot, commission) do
    leg
    |> close(as_of, "expired", 0.0, leg.commission)
    |> event("wheel", "expire", as_of, Wheel.cash(action, commission), %{
      "spot" => Map.get(snapshot.expiry_spots, leg.expiration, snapshot.spot)
    })
  end

  defp apply_wheel({:assign, leg} = action, id, as_of, _lot, snapshot, commission) do
    trade = open_trade("wheel", id, "shares", as_of)

    lot =
      Repo.insert!(%Position{
        trade_id: trade.id,
        underlying_instrument_id: id,
        kind: "shares",
        side: "long",
        quantity: leg.quantity * Wheel.multiplier(),
        open_price: leg.strike,
        opened_on: as_of
      })

    leg
    |> close(as_of, "assigned", 0.0, leg.commission)
    |> event("wheel", "assign", as_of, Wheel.cash(action, commission), %{
      "spot" => Map.get(snapshot.expiry_spots, leg.expiration, snapshot.spot),
      "shares_position_id" => lot.id
    })
  end

  defp apply_wheel({:call_away, leg} = action, _id, as_of, lot, snapshot, commission) do
    close(lot, as_of, "called_away", leg.strike, lot.commission)

    leg
    |> close(as_of, "called_away", 0.0, leg.commission)
    |> event("wheel", "call_away", as_of, Wheel.cash(action, commission), %{
      "spot" => Map.get(snapshot.expiry_spots, leg.expiration, snapshot.spot)
    })
  end

  # The other books' actions: whole trades open, close and settle together.

  defp apply_trade({:hold, _trade}, _book, _id, _as_of, _snapshot, _commission), do: :ok

  defp apply_trade({:open, structure, legs}, book, id, as_of, snapshot, commission) do
    trade = open_trade(book, id, structure, as_of)

    for leg <- legs do
      position =
        Repo.insert!(%Position{
          trade_id: trade.id,
          underlying_instrument_id: id,
          contract_id: leg.contract_id,
          kind: leg.kind,
          side: leg.side,
          quantity: leg.quantity,
          strike: leg.strike,
          expiration: leg.expiration,
          open_price: leg.open_price,
          opened_on: as_of,
          commission: commission * leg.quantity
        })

      event(position, book, "open", as_of, Legs.open_cash([leg], commission), %{
        "spot" => snapshot.spot,
        "bid" => leg.bid,
        "ask" => leg.ask,
        "delta" => leg.delta,
        "dte" => Date.diff(leg.expiration, as_of)
      })
    end
  end

  defp apply_trade({:close, _trade, fills}, book, _id, as_of, snapshot, commission) do
    for {leg, price} <- fills do
      leg
      |> close(as_of, "closed", price, leg.commission + commission * leg.quantity)
      |> event(book, "close", as_of, Legs.close_cash([{leg, price}], commission), %{
        "spot" => snapshot.spot,
        "price" => price
      })
    end
  end

  # Half the contracts sold: they become their own closed position in the
  # trade, and the rest stay open, each part with its share of the opening
  # commission.
  defp apply_trade(
         {:sell_half, _trade, leg, price} = action,
         book,
         _id,
         as_of,
         snapshot,
         commission
       ) do
    %{quantity: sold} = Legs.half(leg)
    per_contract = leg.commission / leg.quantity

    leg
    |> Ecto.Changeset.change(
      quantity: leg.quantity - sold,
      commission: per_contract * (leg.quantity - sold)
    )
    |> Repo.update!()

    Position
    |> struct(Map.take(leg, ~w(trade_id underlying_instrument_id contract_id side kind strike
        expiration open_price opened_on)a))
    |> Map.merge(%{quantity: sold, commission: per_contract * sold})
    |> Repo.insert!()
    |> close(as_of, "closed", price, (per_contract + commission) * sold)
    |> event(book, "close", as_of, Legs.cash(action, commission), %{
      "spot" => snapshot.spot,
      "price" => price,
      "half" => true
    })
  end

  defp apply_trade({:settle, trade, spot}, book, _id, as_of, _snapshot, _commission) do
    for leg <- trade.legs do
      value = Legs.intrinsic(leg.kind, leg.strike, spot)

      leg
      |> close(as_of, "expired", value, leg.commission)
      |> event(book, "expire", as_of, Legs.settle_cash([leg], spot), %{
        "spot" => spot,
        "intrinsic" => value
      })
    end
  end

  defp open_trade(book, id, structure, as_of),
    do:
      Repo.insert!(%Trade{
        strategy: book,
        underlying_instrument_id: id,
        structure: structure,
        opened_on: as_of
      })

  defp close_trade(trade_id, as_of) do
    Trade
    |> Repo.get!(trade_id)
    |> Ecto.Changeset.change(status: "closed", closed_on: as_of)
    |> Repo.update!()
  end

  # Closing a position closes its trade once none of the trade's legs is
  # left open (a wheel trade has a single position).
  defp close(position, as_of, status, price, commission) do
    closed =
      position
      |> Ecto.Changeset.change(
        status: status,
        close_price: price,
        closed_on: as_of,
        commission: commission
      )
      |> Repo.update!()

    if not Repo.exists?(
         from(p in Position, where: p.trade_id == ^closed.trade_id and p.status == "open")
       ),
       do: close_trade(closed.trade_id, as_of)

    closed
  end

  # A nightly mark for everything still open: the quote's mid for a leg, the
  # spot for shares.
  defp mark(book, id, as_of, snapshot) do
    for position <- open_positions(book, id) do
      mid =
        if position.kind == "shares",
          do: snapshot.spot,
          else: Wheel.mid(Map.get(snapshot.quotes, position.contract_id))

      event(position, book, "mark", as_of, 0.0, %{"spot" => snapshot.spot, "mid" => mid})
    end
  end

  defp event(position, book, kind, as_of, cash, detail) do
    Repo.insert!(%Event{
      position_id: position.id,
      underlying_instrument_id: position.underlying_instrument_id,
      strategy: book,
      on: as_of,
      kind: kind,
      cash: cash,
      detail: detail
    })
  end

  @doc """
  One book for the Options page: cash, marked value and P&L against the
  starting cash, net premium (sold less bought), open option legs and share
  lots with their marks, its trades, buy-and-hold of its underlyings since
  its first night, and its latest events (marks left out). The wheel's
  trades are its cycles, one per underlying; every other book's are the
  trades it opened.
  """
  @spec book(String.t()) :: map()
  def book(strategy \\ "wheel") do
    start = config()[:starting_cash]

    positions =
      Repo.all(
        with_symbol(
          from(p in Position,
            join: t in Trade,
            on: t.id == p.trade_id,
            where: t.strategy == ^strategy,
            order_by: [desc: p.id]
          )
        )
      )

    events =
      Repo.all(
        with_symbol(
          from(e in Event, where: e.strategy == ^strategy, order_by: [desc: e.on, desc: e.id])
        )
      )

    open = Enum.filter(positions, &(&1.status == "open"))
    live = live_quotes(open)

    marks =
      events
      |> Enum.filter(&(&1.kind == "mark"))
      |> Enum.uniq_by(& &1.position_id)
      |> Map.new(&{&1.position_id, &1.detail["mid"]})
      |> Map.merge(Map.new(live, fn {id, quote} -> {id, Wheel.mid(quote)} end))

    spots =
      events
      |> latest_spots()
      |> Map.merge(live_spots(open, live))

    options = Enum.filter(positions, &(&1.kind in ~w(put call)))

    legs =
      for %{kind: kind} = p <- open, kind in ~w(put call) do
        mark = marks[p.id]
        pnl = mark && Legs.sign(p) * (p.open_price - mark) * Wheel.multiplier() * p.quantity
        %{position: p, mark: mark, pnl: pnl}
      end

    lots =
      for %{kind: "shares"} = p <- open do
        mark = marks[p.id]
        %{position: p, mark: mark, pnl: mark && (mark - p.open_price) * p.quantity}
      end

    cash = start + Enum.sum_by(events, & &1.cash)
    value = cash + Enum.sum_by(open, &held_value(&1, marks[&1.id]))

    %{
      strategy: strategy,
      starting_cash: start,
      cash: cash,
      value: value,
      pnl: value - start,
      return: value / start - 1,
      premium: Legs.net_premium(options) * Wheel.multiplier(),
      legs: legs,
      lots: lots,
      trades: trades(strategy, positions, events, marks, spots),
      priced_at: live |> Map.values() |> Enum.map(& &1.captured_at) |> Enum.max(fn -> nil end),
      hold_return: hold_return(events),
      started_on: events |> List.last() |> then(&(&1 && &1.on)),
      events: events |> Enum.reject(&(&1.kind == "mark")) |> Enum.take(@recent_events)
    }
  end

  @doc "Every book's P&L added up (marked to the latest quotes), for the tab badge."
  @spec total_pnl() :: float()
  def total_pnl, do: Enum.sum_by(books(), &book(&1).pnl) / 1

  @doc "How many trades each book has open, for the tab badges."
  @spec open_counts() :: %{String.t() => non_neg_integer()}
  def open_counts do
    from(t in Trade,
      where: t.status == "open",
      group_by: t.strategy,
      select: {t.strategy, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Each open option leg's latest quote with a mid, by position id: never
  # older than its nightly mark, which came from a stored quote too.
  defp live_quotes(open) do
    legs = Enum.filter(open, &(&1.kind in ~w(put call)))
    quotes = latest_quotes(Enum.map(legs, & &1.contract_id), ~U[2000-01-01 00:00:00Z])

    for leg <- legs,
        quote = quotes[leg.contract_id],
        Wheel.mid(quote),
        into: %{},
        do: {leg.id, quote}
  end

  # Each underlying's spot from its newest live quote.
  defp live_spots(open, live) do
    symbols = Map.new(open, &{&1.id, &1.symbol})

    live
    |> Enum.sort_by(fn {_id, quote} -> quote.captured_at end, NaiveDateTime)
    |> Map.new(fn {id, quote} -> {symbols[id], quote.spot} end)
  end

  defp latest_spots(events) do
    events
    |> Enum.filter(&(&1.kind == "mark"))
    |> Enum.uniq_by(& &1.symbol)
    |> Map.new(&{&1.symbol, &1.detail["spot"]})
  end

  # The wheel: one trade per underlying, its legs in order, its stage, the
  # premium it has collected, and its P&L (its events' cash plus what its
  # open positions are marked at).
  defp trades("wheel", positions, events, marks, spots) do
    positions
    |> Enum.group_by(& &1.symbol)
    |> Enum.map(fn {symbol, mine} ->
      legs = Enum.sort_by(mine, & &1.id)
      open = Enum.filter(legs, &(&1.status == "open"))
      short = Enum.find(open, &(&1.kind in ~w(put call)))
      shares = Enum.find(open, &(&1.kind == "shares"))

      %{
        symbol: symbol,
        legs: legs,
        short: short,
        shares: shares,
        stage: stage(short, shares),
        premium: legs |> Enum.filter(&(&1.kind in ~w(put call))) |> premium_sold(),
        pnl: pnl_of(legs, events, marks),
        spot: spots[symbol]
      }
    end)
    |> Enum.sort_by(& &1.symbol)
  end

  # Every other book: the trades it opened, newest first, each with its
  # legs, what it can make and lose at expiry, and its P&L.
  defp trades(strategy, positions, events, marks, spots) do
    by_trade = Enum.group_by(positions, & &1.trade_id)

    from(t in Trade, where: t.strategy == ^strategy, order_by: [desc: t.id])
    |> with_symbol()
    |> Repo.all()
    |> Enum.map(fn trade ->
      legs = by_trade |> Map.get(trade.id, []) |> Enum.sort_by(&{&1.strike, &1.kind})

      %{
        id: trade.id,
        symbol: trade.symbol,
        structure: trade.structure,
        status: trade.status,
        opened_on: trade.opened_on,
        closed_on: trade.closed_on,
        legs: legs,
        expiration: legs |> List.first() |> then(&(&1 && &1.expiration)),
        summary: Legs.summary(legs),
        marks: Map.new(legs, &{&1.id, marks[&1.id]}),
        pnl: pnl_of(legs, events, marks),
        spot: spots[trade.symbol]
      }
    end)
  end

  defp pnl_of(legs, events, marks) do
    ids = MapSet.new(legs, & &1.id)
    cash = events |> Enum.filter(&MapSet.member?(ids, &1.position_id)) |> Enum.sum_by(& &1.cash)
    open = Enum.filter(legs, &(&1.status == "open"))
    cash + Enum.sum_by(open, &held_value(&1, marks[&1.id]))
  end

  defp stage(nil, nil), do: :waiting
  defp stage(%{kind: "put"}, _shares), do: :short_put
  defp stage(%{kind: "call"}, _shares), do: :covered_call
  defp stage(nil, _shares), do: :holding_shares

  # What an open position is worth to the book: shares at their mark, a
  # short leg as the cost to buy it back, a long leg as what it would sell for.
  defp held_value(%{kind: "shares"} = p, mark), do: (mark || p.open_price) * p.quantity

  defp held_value(p, mark),
    do: -Legs.sign(p) * (mark || p.open_price) * Wheel.multiplier() * p.quantity

  @doc """
  Workbench parameters (`Opus.Options.scenarios/1`) for an open wheel leg's
  payoff chart: the leg as sold, valued at the latest spot and implied vol.
  `cost_basis` is the shares' cost for a covered call.
  """
  @spec scenario_params(map(), float() | nil) :: map()
  def scenario_params(%{position: p, quote: quote, marks: marks}, cost_basis \\ nil) do
    spot = (quote && quote.spot) || (List.last(marks) || %{})[:spot]

    %{
      "strategy" => if(p.kind == "put", do: "cash_secured_put", else: "covered_call"),
      "underlying" => p.symbol,
      "strike" => to_string(p.strike),
      "premium" => to_string(p.open_price),
      "expiration" => Date.to_iso8601(p.expiration),
      "contracts" => to_string(p.quantity),
      "spot" => text(spot),
      "sigma" => text(quote && quote.iv_pct),
      "cost_basis" => text(cost_basis)
    }
  end

  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  @doc """
  The engine request (`Opus.Options.structure_scenarios/1`) for a trade's
  payoff chart: every open leg as opened, each with its latest implied vol,
  valued at the latest spot.
  """
  @spec structure_request(map()) :: map()
  def structure_request(%{symbol: symbol, legs: legs, spot: spot}) do
    open = Enum.filter(legs, &(&1.status == "open" and &1.kind in ~w(put call)))

    %{
      underlying: symbol,
      expiration: open |> List.first() |> Map.fetch!(:expiration) |> Date.to_iso8601(),
      legs:
        for leg <- open do
          quote = latest_quote(leg.contract_id)

          %{
            kind: leg.kind,
            side: if(leg.side == "short", do: "sell", else: "buy"),
            strike: leg.strike,
            premium: leg.open_price,
            contracts: leg.quantity,
            sigma: quote && quote.iv_pct && quote.iv_pct / 100
          }
        end
    }
    |> then(&if(is_number(spot), do: Map.put(&1, :spot, spot), else: &1))
  end

  @doc """
  One position for its detail panel: the position, its nightly marks, its
  own events, the latest stored quote for its contract, and (for a wheel
  leg) the take-profit price and the 21-day management date. Nil if there
  is no such position.
  """
  @spec leg(integer()) :: map() | nil
  def leg(id) do
    with %Position{} = position <- Repo.one(with_symbol(from(p in Position, where: p.id == ^id))) do
      {marks, events} =
        from(e in Event, where: e.position_id == ^id, order_by: [asc: e.on, asc: e.id])
        |> Repo.all()
        |> Enum.split_with(&(&1.kind == "mark"))

      %{
        position: position,
        marks: Enum.map(marks, &%{on: &1.on, mid: &1.detail["mid"], spot: &1.detail["spot"]}),
        events: events,
        quote: latest_quote(position.contract_id),
        take_profit_price: position.kind in ~w(put call) && Wheel.take_profit_price(position),
        manage_on: position.kind in ~w(put call) && Wheel.manage_on(position)
      }
    end
  end

  defp latest_quote(nil), do: nil

  defp latest_quote(contract_id) do
    from(q in "option_quotes",
      where: q.contract_id == ^contract_id,
      order_by: [desc: q.captured_at],
      limit: 1,
      select: %{
        bid: q.bid,
        ask: q.ask,
        delta: q.delta,
        iv_pct: q.volatility,
        spot: q.spot,
        captured_at: type(q.captured_at, :naive_datetime_usec)
      }
    )
    |> Repo.one()
  end

  defp with_symbol(query) do
    from(r in query,
      join: i in "instruments",
      on: i.id == r.underlying_instrument_id,
      select: %{r | symbol: i.symbol}
    )
  end

  defp premium_sold(legs),
    do: Enum.sum_by(legs, &(&1.open_price * Wheel.multiplier() * &1.quantity))

  # Equal-weight buy-and-hold of the book's underlyings from each one's first
  # recorded spot to its latest.
  defp hold_return(events) do
    returns =
      events
      |> Enum.filter(&is_number(&1.detail["spot"]))
      |> Enum.group_by(& &1.symbol, & &1.detail["spot"])
      |> Enum.map(fn {_symbol, [latest | _] = spots} -> latest / List.last(spots) - 1 end)

    if returns == [], do: nil, else: Enum.sum(returns) / length(returns)
  end
end
