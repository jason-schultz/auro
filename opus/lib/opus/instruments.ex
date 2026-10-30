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
    |> create()
  end

  @spec create(map()) :: {:ok, Instrument.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Instrument{}
    |> Instrument.changeset(attrs)
    |> Repo.insert()
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
  Have Rust ask Questrade who each listing with a Questrade spelling is and
  record the symbol id, exchange and currency it reports.
  """
  @spec enrich() :: {:ok, map()} | {:error, term()}
  def enrich, do: Client.enrich_instruments()
end
