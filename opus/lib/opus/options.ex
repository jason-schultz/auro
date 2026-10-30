defmodule Opus.Options do
  @moduledoc """
  Options what-if for the options page.

  The page collects a single-leg position as typed; this module turns the
  strings into the engine's request and hands back the engine's analysis
  (`POST /api/options/scenarios`). All option math lives in Rust.
  """

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Options.Idea
  alias Opus.Repo

  # Strikes shown either side of the spot price when picking from a chain.
  @strikes_each_side 8

  # `option_quotes.source` of the held contracts quoted during the session.
  @held_source "questrade_legs"

  # PubSub topic told when a scan has replaced the day's ideas.
  @ideas_topic "options:ideas"

  @strategies [
    {"cash_secured_put", "Sell a put (cash-secured)", "put", "sell"},
    {"covered_call", "Sell a call (covered)", "call", "sell"},
    {"long_call", "Buy a call", "call", "buy"},
    {"long_put", "Buy a put", "put", "buy"}
  ]

  @doc "`option_quotes.source` of the held contracts quoted during the session."
  @spec held_source() :: String.t()
  def held_source, do: @held_source

  @doc "Select options for the form: `{label, value}`."
  @spec strategy_options() :: [{String.t(), String.t()}]
  def strategy_options, do: for({value, label, _, _} <- @strategies, do: {label, value})

  @doc "Whether a strategy sells the option (so its premium is the bid) or buys it (the ask)."
  @spec side(String.t()) :: :sell | :buy
  def side(strategy) do
    case Enum.find(@strategies, &(elem(&1, 0) == strategy)) do
      {_, _, _, "sell"} -> :sell
      _ -> :buy
    end
  end

  @doc "The single-leg strategy for a side and kind: selling a put is the cash-secured put, and so on."
  @spec strategy_for(:buy | :sell, String.t()) :: String.t()
  def strategy_for(side, kind) do
    side = if side == :sell, do: "sell", else: "buy"

    case Enum.find(@strategies, fn {_, _, k, s} -> k == kind and s == side end) do
      {value, _, _, _} -> value
      nil -> "cash_secured_put"
    end
  end

  @doc "The option kind a strategy trades: `\"put\"` or `\"call\"`."
  @spec kind(String.t()) :: String.t()
  def kind(strategy) do
    case Enum.find(@strategies, &(elem(&1, 0) == strategy)) do
      {_, _, kind, _} -> kind
      nil -> "put"
    end
  end

  @doc """
  Underlyings with a stored option chain, each with when its latest
  snapshot was taken: the nightly Questrade capture for listings flagged
  `feed_options_chain` on the Instruments page.
  """
  @spec underlyings() :: [%{symbol: String.t(), captured_at: NaiveDateTime.t()}]
  def underlyings do
    from(q in "option_quotes",
      join: c in "option_contracts",
      on: c.id == q.contract_id,
      join: i in "instruments",
      on: i.id == c.underlying_instrument_id,
      where: q.source != @held_source,
      group_by: [i.id, i.symbol, i.asset_class],
      order_by: i.symbol,
      select: %{
        symbol: i.symbol,
        instrument_id: i.id,
        asset_class: i.asset_class,
        captured_at: type(max(q.captured_at), :naive_datetime_usec)
      }
    )
    |> Repo.all()
  end

  @doc """
  Every contract of either kind in the latest snapshot expiring between
  `dte_min` and `dte_max` days from today, with its quote: the scan's raw
  material.
  """
  @spec candidates(String.t(), pos_integer(), pos_integer()) :: [map()]
  def candidates(symbol, dte_min, dte_max) do
    today = Opus.Clock.today()
    first = Date.add(today, dte_min)
    last = Date.add(today, dte_max)

    symbol
    |> latest_quotes()
    |> where([q, c, i], c.expiration_date >= ^first and c.expiration_date <= ^last)
    |> order_by([q, c, i], [c.expiration_date, c.contract_type, c.strike])
    |> select([q, c, i], %{
      contract_id: c.id,
      symbol: i.symbol,
      kind: c.contract_type,
      strike: c.strike,
      expiration: c.expiration_date,
      bid: q.bid,
      ask: q.ask,
      volatility: q.volatility,
      delta: q.delta,
      open_interest: q.open_interest,
      spot: q.spot
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :dte, Date.diff(&1.expiration, today)))
  end

  @doc """
  The most recent scan's ideas, best score first, with the underlying's
  symbol and `chain_at`, when the chain snapshot the idea was read from was
  taken.
  """
  @spec latest_ideas() :: {Date.t() | nil, [Idea.t()]}
  def latest_ideas do
    case Repo.one(from(i in Idea, select: max(i.scanned_on))) do
      nil ->
        {nil, []}

      scanned_on ->
        ideas =
          from(i in Idea,
            join: u in "instruments",
            on: u.id == i.underlying_instrument_id,
            where: i.scanned_on == ^scanned_on,
            order_by: [asc: i.list, desc: i.score],
            select: %{i | symbol: u.symbol}
          )
          |> Repo.all()

        {scanned_on, with_chain_at(ideas, scanned_on)}
    end
  end

  # Each idea's chain capture: the latest chain quote of its contract taken
  # on the scan's date, no later than the scan recorded the idea.
  defp with_chain_at([], _scanned_on), do: []

  defp with_chain_at(ideas, scanned_on) do
    ids = ideas |> Enum.map(& &1.contract_id) |> Enum.uniq()

    captures =
      from(q in "option_quotes",
        where:
          q.contract_id in type(^ids, {:array, :integer}) and q.source != @held_source and
            q.captured_at >= type(^Opus.Clock.midnight(scanned_on), :utc_datetime_usec),
        select: {q.contract_id, type(q.captured_at, :naive_datetime_usec)}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(ideas, fn idea ->
      recorded = DateTime.to_naive(idea.inserted_at)

      chain_at =
        captures
        |> Map.get(idea.contract_id, [])
        |> Enum.filter(&(NaiveDateTime.compare(&1, recorded) != :gt))
        |> Enum.max(NaiveDateTime, fn -> nil end)

      %{idea | chain_at: chain_at}
    end)
  end

  @doc """
  Set an idea's status. `{:error, :not_found}` when the row is gone: a
  re-scan replaces the day's ideas with new rows.
  """
  @spec set_idea_status(integer() | String.t(), String.t()) ::
          {:ok, Idea.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_idea_status(id, status) do
    case Repo.get(Idea, id) do
      nil -> {:error, :not_found}
      idea -> idea |> Idea.status_changeset(status) |> Repo.update()
    end
  end

  @doc "Subscribe the caller to `{:ideas_updated, scanned_on}` after each scan."
  @spec subscribe_ideas() :: :ok | {:error, term()}
  def subscribe_ideas, do: Phoenix.PubSub.subscribe(Opus.PubSub, @ideas_topic)

  @doc "Tell subscribers a scan has recorded `scanned_on`'s ideas."
  @spec broadcast_ideas(Date.t()) :: :ok | {:error, term()}
  def broadcast_ideas(scanned_on),
    do: Phoenix.PubSub.broadcast(Opus.PubSub, @ideas_topic, {:ideas_updated, scanned_on})

  @doc "Expiration dates in an underlying's latest snapshot, nearest first."
  @spec expiries(String.t()) :: [Date.t()]
  def expiries(symbol) do
    symbol
    |> latest_quotes()
    |> group_by([q, c, i], c.expiration_date)
    |> order_by([q, c, i], c.expiration_date)
    |> select([q, c, i], c.expiration_date)
    |> Repo.all()
  end

  @doc """
  The strikes of one kind at one expiry from the latest snapshot, the
  nearest to the spot price either side, each with the quote the page
  shows, the spot and capture time they were taken at, and `at_the_money`
  on the strike closest to the spot. `each_side: :all` keeps every strike.
  """
  @spec chain(String.t(), Date.t(), String.t(), keyword()) :: [map()]
  def chain(symbol, %Date{} = expiration, kind, opts \\ []) do
    each_side = Keyword.get(opts, :each_side, @strikes_each_side)

    rows =
      symbol
      |> latest_quotes()
      |> where([q, c, i], c.expiration_date == ^expiration and c.contract_type == ^kind)
      |> order_by([q, c, i], c.strike)
      |> select([q, c, i], %{
        strike: c.strike,
        bid: q.bid,
        ask: q.ask,
        last: q.last,
        volatility: q.volatility,
        delta: q.delta,
        open_interest: q.open_interest,
        spot: q.spot,
        captured_at: type(q.captured_at, :naive_datetime_usec)
      })
      |> Repo.all()

    case rows do
      [] ->
        []

      [%{spot: spot} | _] ->
        nearest =
          rows |> Enum.map(&abs(&1.strike - spot)) |> Enum.with_index() |> Enum.min() |> elem(1)

        {first, count} =
          if each_side == :all,
            do: {0, length(rows)},
            else: {max(nearest - each_side, 0), 2 * each_side + 1}

        rows
        |> Enum.with_index()
        |> Enum.slice(first, count)
        |> Enum.map(fn {row, i} -> Map.put(row, :at_the_money, i == nearest) end)
    end
  end

  @doc """
  Every contract in an underlying's latest snapshot, any expiry, with its
  quote and the spot and capture time: what the paper book reads each night.
  """
  @spec snapshot(String.t()) :: [map()]
  def snapshot(symbol) do
    symbol
    |> latest_quotes()
    |> select([q, c, i], %{
      contract_id: c.id,
      instrument_id: i.id,
      kind: c.contract_type,
      strike: c.strike,
      expiration: c.expiration_date,
      bid: q.bid,
      ask: q.ask,
      delta: q.delta,
      spot: q.spot,
      captured_at: type(q.captured_at, :naive_datetime_usec)
    })
    |> Repo.all()
  end

  # Quotes from the latest capture of an underlying's whole chain: the
  # chain snapshot writes one capture time per underlying per run. The
  # session's held-contract quotes (`Opus.Options.IntradayWorker`, source
  # "questrade_legs") cover a handful of contracts and never count as the
  # chain, or the paper books, the ideas scan and the chain view would read
  # those few contracts as everything listed.
  defp latest_quotes(symbol) do
    latest =
      from(q in "option_quotes",
        join: c in "option_contracts",
        on: c.id == q.contract_id,
        join: i in "instruments",
        on: i.id == c.underlying_instrument_id,
        where: i.symbol == ^symbol and q.source != @held_source,
        select: max(q.captured_at)
      )

    from(q in "option_quotes",
      join: c in "option_contracts",
      on: c.id == q.contract_id,
      join: i in "instruments",
      on: i.id == c.underlying_instrument_id,
      where:
        i.symbol == ^symbol and q.captured_at == subquery(latest) and
          q.source != @held_source
    )
  end

  @doc """
  Analyse the position described by the form params (string keys, string
  values as typed). Returns the engine's analysis map or a reason the page
  can show.
  """
  @spec scenarios(map()) :: {:ok, map()} | {:error, term()}
  def scenarios(params) when is_map(params) do
    with {:ok, request} <- build_request(params) do
      Client.option_scenarios(request)
    end
  end

  @doc """
  The engine's analysis of several legs as one structure (a spread, an iron
  condor): `request` has `underlying`, `expiration`, `legs` (each `kind`,
  `side` buy/sell, `strike`, `premium`, `contracts`, `sigma`) and optionally
  `spot`. The legs' payoff curves come back added together.
  """
  @spec structure_scenarios(map()) :: {:ok, map()} | {:error, term()}
  def structure_scenarios(request), do: Client.option_scenarios(request)

  @doc false
  @spec build_request(map()) :: {:ok, map()} | {:error, String.t()}
  def build_request(params) do
    with {:ok, {kind, side}} <- strategy(params["strategy"]),
         {:ok, underlying} <- required_text(params["underlying"], "Underlying"),
         {:ok, strike} <- required_number(params["strike"], "Strike"),
         {:ok, premium} <- required_number(params["premium"], "Premium"),
         {:ok, expiration} <- required_date(params["expiration"]),
         {:ok, contracts} <- optional_number(params["contracts"], "Contracts"),
         {:ok, spot} <- optional_number(params["spot"], "Spot"),
         {:ok, sigma_pct} <- optional_number(params["sigma"], "Volatility"),
         {:ok, cost_basis} <- optional_number(params["cost_basis"], "Cost basis") do
      request =
        %{
          underlying: underlying,
          kind: kind,
          side: side,
          strike: strike,
          premium: premium,
          expiration: Date.to_iso8601(expiration),
          contracts: contracts || 1.0
        }
        |> maybe_put(:spot, spot)
        |> maybe_put(:sigma, sigma_pct && sigma_pct / 100)
        |> maybe_put(:cost_basis, cost_basis)

      {:ok, request}
    end
  end

  defp strategy(value) do
    case Enum.find(@strategies, &(elem(&1, 0) == value)) do
      {_, _, kind, side} -> {:ok, {kind, side}}
      nil -> {:error, "Pick a strategy."}
    end
  end

  defp required_text(value, label) do
    case value && String.trim(value) do
      text when is_binary(text) and text != "" -> {:ok, String.upcase(text)}
      _ -> {:error, "#{label} is required."}
    end
  end

  defp required_number(value, label) do
    case optional_number(value, label) do
      {:ok, nil} -> {:error, "#{label} is required."}
      other -> other
    end
  end

  defp optional_number(nil, _label), do: {:ok, nil}

  defp optional_number(value, label) when is_binary(value) do
    case value |> String.trim() |> String.replace(["$", ",", "%"], "") do
      "" ->
        {:ok, nil}

      text ->
        case Float.parse(text) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, "#{label} must be a positive number."}
        end
    end
  end

  defp required_date(value) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "Expiration must be a date."}
    end
  end

  defp required_date(_), do: {:error, "Expiration is required."}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
