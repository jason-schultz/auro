defmodule Opus.Instruments do
  @moduledoc """
  The security master: every listing Auro knows, with the spelling each
  vendor uses for it and the feeds that store data for it.

  Opus owns the rows (the instruments page adds listings and flips flags);
  the market-data workers read the feed lists from here instead of config;
  Rust reads the table to know what to fetch and records the vendor ids it
  learns (`POST /api/instruments/enrich` fills Questrade's).
  """

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Instruments.Instrument
  alias Opus.MarketData.ShareHistoryWorker
  alias Opus.Repo

  @type feed :: :questrade_bars | :questrade_daily | :massive_daily | :options_chain

  @canadian_suffixes %{"TO" => "TSX", "VN" => "TSXV", "CN" => "CNSX"}
  @canadian_exchanges Map.values(@canadian_suffixes)

  @doc """
  Every listing, exchange then symbol. Options narrow it: `:search` matches
  any spelling, `:group` is `"oanda"`, `"canada"` or `"us"`, and
  `active_only: true` hides retired listings.
  """
  @spec list(keyword()) :: [Instrument.t()]
  def list(opts \\ []) do
    Instrument
    |> search(opts[:search])
    |> group(opts[:group])
    |> active(opts[:active_only])
    |> order_by([i], asc: i.exchange, asc: i.symbol)
    |> Repo.all()
  end

  defp group(query, "oanda"), do: where(query, [i], i.exchange == "OANDA")
  defp group(query, "canada"), do: where(query, [i], i.exchange in ^@canadian_exchanges)

  defp group(query, "us"),
    do: where(query, [i], i.exchange != "OANDA" and i.exchange not in ^@canadian_exchanges)

  defp group(query, _), do: query

  defp active(query, true), do: where(query, [i], i.active)
  defp active(query, _), do: query

  defp search(query, nil), do: query
  defp search(query, ""), do: query

  defp search(query, term) do
    pattern = "%" <> String.upcase(String.trim(term)) <> "%"

    where(
      query,
      [i],
      ilike(i.symbol, ^pattern) or ilike(i.questrade_symbol, ^pattern) or
        ilike(i.oanda_symbol, ^pattern) or ilike(i.massive_ticker, ^pattern)
    )
  end

  @spec get!(integer() | String.t()) :: Instrument.t()
  def get!(id), do: Repo.get!(Instrument, id)

  @doc """
  The master id of a listing named the way any vendor spells it
  (`EUR_USD`, `RY.TO`, `SPY`), while the older tables still carry text.
  """
  @spec id_for(String.t() | nil) :: {:ok, integer()} | :error
  def id_for(name) when is_binary(name) do
    Instrument
    |> where(
      [i],
      i.oanda_symbol == ^name or i.questrade_symbol == ^name or i.massive_ticker == ^name
    )
    |> select([i], i.id)
    |> Repo.one()
    |> case do
      nil -> :error
      id -> {:ok, id}
    end
  end

  def id_for(_), do: :error

  @doc """
  The vendor spellings of the active listings flagged for `feed`, in the
  order the workers run them. This is what the feed lists in config used
  to be.
  """
  @spec feed_symbols(feed()) :: [String.t()]
  def feed_symbols(:questrade_bars),
    do: Enum.uniq(flagged(:feed_questrade_bars, :questrade_symbol) ++ held(held_query()))

  # Daily bars from Questrade for what's held and not already fed daily by
  # Massive (US listings): Canadian holdings have no other daily source.
  def feed_symbols(:questrade_daily),
    do: held_query() |> where([i], not i.feed_massive_daily) |> held()

  def feed_symbols(:massive_daily), do: flagged(:feed_massive_daily, :massive_ticker)
  def feed_symbols(:options_chain), do: flagged(:feed_options_chain, :questrade_symbol)

  # Listings with shares held on Wealthsimple: tracked like any flagged
  # listing whether or not a strategy can trade them, so the list follows
  # the holdings (a sold position drops out, a new one joins).
  defp held_query do
    from(i in Instrument,
      join: p in "wealthsimple_positions",
      on: p.instrument_id == i.id,
      where: i.active and p.shares > 0 and not is_nil(i.questrade_symbol)
    )
  end

  defp held(query),
    do: query |> distinct(true) |> select([i], i.questrade_symbol) |> Repo.all() |> Enum.sort()

  defp flagged(flag, symbol_column) do
    Instrument
    |> where([i], i.active and field(i, ^flag) == true)
    |> where([i], not is_nil(field(i, ^symbol_column)))
    |> order_by([i], asc: i.exchange, asc: i.symbol)
    |> select([i], field(i, ^symbol_column))
    |> Repo.all()
  end

  @doc """
  Add a listing typed the way a vendor spells it: `RY.TO`, `DMGI.VN` and
  `HODL.CN` are Canadian listings in Questrade notation, `EUR_USD` is an
  OANDA name, anything else is a US listing known to Questrade and Massive
  alike. A US listing starts on the placeholder exchange `US` until the
  Questrade enrich pass names the real one.
  """
  @spec add(String.t(), String.t()) :: {:ok, Instrument.t()} | {:error, Ecto.Changeset.t()}
  def add(spelling, asset_class) when is_binary(spelling) and is_binary(asset_class) do
    spelling
    |> String.trim()
    |> String.upcase()
    |> listing()
    |> Map.put(:asset_class, asset_class)
    |> then(&Map.put(&1, :test_broker, default_broker(&1)))
    |> create()
    |> tap(&ready_to_test/1)
  end

  # A market held as shares needs its history and dividends before it can
  # be tested: queue them (`Opus.MarketData.ShareHistoryWorker`).
  defp ready_to_test({:ok, instrument}), do: ShareHistoryWorker.enqueue(instrument)
  defp ready_to_test(_error), do: :ok

  @spec create(map()) :: {:ok, Instrument.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Instrument{}
    |> Instrument.changeset(attrs)
    |> Repo.insert()
  end

  # The broker a new listing's tests assume: OANDA for an OANDA market,
  # Wealthsimple (traded by hand there) for a stock or ETF, none otherwise.
  defp default_broker(%{oanda_symbol: name}) when is_binary(name), do: "oanda"
  defp default_broker(%{asset_class: class}) when class in ~w(equity etf), do: "wealthsimple"
  defp default_broker(_listing), do: nil

  @doc """
  The names among `names` whose market has no broker set for its tests
  (`test_broker`), in order: there are no costs to grade them on, so they
  aren't tested (the engine refuses them too). A name is matched in any
  vendor's spelling.
  """
  @spec without_broker([String.t()]) :: [String.t()]
  def without_broker(names) do
    with_broker =
      from(i in Instrument,
        where:
          not is_nil(i.test_broker) and
            (i.oanda_symbol in ^names or i.questrade_symbol in ^names or
               i.massive_ticker in ^names),
        select: [i.oanda_symbol, i.questrade_symbol, i.massive_ticker]
      )
      |> Repo.all()
      |> List.flatten()
      |> MapSet.new()

    Enum.reject(names, &MapSet.member?(with_broker, &1))
  end

  @doc "Why `names` (from `without_broker/1`) can't be tested, in plain words."
  @spec without_broker_words([String.t()]) :: String.t()
  def without_broker_words([name]),
    do:
      "#{name} has no broker set for its tests, so there are no costs to grade it on. " <>
        "Pick one on the Instruments page."

  def without_broker_words(names),
    do:
      "#{Enum.join(names, ", ")} have no broker set for their tests, so there are no costs " <>
        "to grade them on. Pick one on the Instruments page."

  @doc """
  Why the markets in `names` can't be tested yet, or nil: the first of
  `{:no_broker, names}` (no costs to grade them on) and `{:no_dividends,
  names}` (held as shares, so a test pays their dividends, and those were
  never loaded). The engine refuses both too; this says so before a test
  is queued.
  """
  @spec untestable([String.t()]) :: nil | {:no_broker | :no_dividends, [String.t()]}
  def untestable(names) do
    case {without_broker(names), without_dividends(names)} do
      {[], []} -> nil
      {[], off} -> {:no_dividends, off}
      {off, _} -> {:no_broker, off}
    end
  end

  @doc "`untestable/1`'s reason in plain words, with what to do."
  @spec untestable_words({:no_broker | :no_dividends, [String.t()]}) :: String.t()
  def untestable_words({:no_broker, names}), do: without_broker_words(names)

  def untestable_words({:no_dividends, names}),
    do:
      "#{Enum.join(names, ", ")}: tested as shares owned outright, which are paid " <>
        "dividends, and they haven't been loaded yet, so a test would leave that cash out. " <>
        "Load them with Load dividends (here or on the Instruments page), then test."

  @doc "Whether dividends can be loaded for the market `name` (a US listing Massive covers)."
  @spec dividend_source?(String.t()) :: boolean()
  def dividend_source?(name),
    do: match?(%Instrument{massive_ticker: t} when is_binary(t), find(name))

  @doc """
  Load the dividends of the market `name` (in any vendor's spelling) through
  the live engine: `{:ok, count}`, or `{:error, :no_source}` for a listing
  Massive doesn't cover, or the engine's error.
  """
  @spec load_dividends(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_dividends(name) do
    case find(name) do
      %Instrument{massive_ticker: ticker} when is_binary(ticker) ->
        with {:ok, %{"dividends" => count}} <- Client.persist_dividends(ticker), do: {:ok, count}

      _ ->
        {:error, :no_source}
    end
  end

  @doc "Whether the market `name` (in any vendor's spelling) is in the instruments table."
  @spec known?(String.t()) :: boolean()
  def known?(name), do: find(name) != nil

  @doc "The brokers whose tests hold shares outright (no overnight cost), so pay dividends."
  @spec share_brokers() :: [String.t()]
  def share_brokers,
    do: Repo.all(from(b in "brokers", where: b.overnight_cost == "none", select: b.name))

  @doc """
  Whether the market `name` is tested as shares held (its test broker is a
  share broker, e.g. Wealthsimple): live, its signals are share alerts you
  act on by hand, not OANDA trades.
  """
  @spec share_market?(String.t()) :: boolean()
  def share_market?(name) do
    case find(name) do
      %Instrument{test_broker: broker} when is_binary(broker) -> broker in share_brokers()
      _ -> false
    end
  end

  defp find(name) do
    Repo.one(
      from(i in Instrument,
        where:
          i.oanda_symbol == ^name or i.questrade_symbol == ^name or i.massive_ticker == ^name,
        limit: 1
      )
    )
  end

  # Markets among `names` held as shares (their test broker charges no
  # overnight cost) whose dividend history can be loaded (Massive covers
  # them) and never was. One with no history to load (a Canadian listing) is
  # tested without it, with the dividends recorded since
  # (`Opus.MarketData.DividendRecordWorker`), and its results say so.
  defp without_dividends(names) do
    missing =
      from(i in "instruments",
        join: b in "brokers",
        on: b.name == i.test_broker,
        where:
          b.overnight_cost == "none" and is_nil(i.dividends_checked_at) and
            not is_nil(i.massive_ticker) and
            (i.oanda_symbol in ^names or i.questrade_symbol in ^names or
               i.massive_ticker in ^names),
        select: [i.oanda_symbol, i.questrade_symbol, i.massive_ticker]
      )
      |> Repo.all()
      |> List.flatten()
      |> MapSet.new()

    Enum.filter(names, &MapSet.member?(missing, &1))
  end

  @doc false
  @spec listing(String.t()) :: map()
  def listing(name) do
    case Regex.run(~r/^(.+)\.(TO|VN|CN)$/, name) do
      [_, symbol, suffix] ->
        %{
          symbol: symbol,
          exchange: Map.fetch!(@canadian_suffixes, suffix),
          currency: "CAD",
          questrade_symbol: name
        }

      nil ->
        listing(name, String.split(name, "_"))
    end
  end

  defp listing(name, [_base, quote]) when byte_size(quote) == 3,
    do: %{symbol: name, exchange: "OANDA", currency: quote, oanda_symbol: name}

  defp listing(name, _),
    do: %{
      symbol: name,
      exchange: "US",
      currency: "USD",
      questrade_symbol: name,
      massive_ticker: name
    }

  @doc "Flip one of the boolean columns (`active` or a feed flag)."
  @spec toggle(Instrument.t(), atom()) :: {:ok, Instrument.t()} | {:error, Ecto.Changeset.t()}
  def toggle(%Instrument{} = instrument, flag) when is_atom(flag) do
    true = flag in Instrument.flags()

    instrument
    |> Ecto.Changeset.change(%{flag => not Map.fetch!(instrument, flag)})
    |> Repo.update()
  end

  @doc """
  The brokers a market can be tested for, `[{name, label}]` (`brokers`),
  each with the costs its tests charge.
  """
  @spec brokers() :: [{String.t(), String.t()}]
  def brokers do
    from(b in "brokers", order_by: b.label, select: {b.name, b.label})
    |> Repo.all()
  end

  @doc """
  Set the broker `instrument`'s tests charge the costs of; nil: not tested.
  A broker that holds shares queues the market's history and dividends.
  """
  @spec set_broker(Instrument.t(), String.t() | nil) ::
          {:ok, Instrument.t()} | {:error, Ecto.Changeset.t()}
  def set_broker(%Instrument{} = instrument, broker) do
    instrument
    |> Instrument.changeset(%{test_broker: broker})
    |> Repo.update()
    |> tap(&ready_to_test/1)
  end

  @doc """
  Have Rust ask Questrade who each listing with a Questrade spelling is and
  record the symbol id, exchange and currency it reports.
  """
  @spec enrich() :: {:ok, map()} | {:error, term()}
  def enrich, do: Client.enrich_instruments()
end
