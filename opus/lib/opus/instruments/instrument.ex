defmodule Opus.Instruments.Instrument do
  @moduledoc """
  One listing in the security master (`instruments`): the bare symbol and
  the exchange that disambiguates dual listings, the spelling each vendor
  uses for it, and the feeds that store data for it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @asset_classes ~w(fx_major fx_cross metal commodity index bond equity etf)
  @flags [:active, :feed_questrade_bars, :feed_massive_daily, :feed_options_chain]

  schema "instruments" do
    field :symbol, :string
    field :exchange, :string
    field :currency, :string
    field :asset_class, :string
    field :figi, :string
    field :active, :boolean, default: true
    field :oanda_symbol, :string
    field :questrade_symbol, :string
    field :questrade_symbol_id, :integer
    field :massive_ticker, :string
    field :feed_questrade_bars, :boolean, default: false
    field :feed_massive_daily, :boolean, default: false
    field :feed_options_chain, :boolean, default: false
    # The broker its tests charge the costs of (`brokers`); none: not tested.
    field :test_broker, :string
    # Its own round-trip spread in basis points, over its broker's default.
    field :spread_bps, :float

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "The closed set of `asset_class` values."
  @spec asset_classes() :: [String.t()]
  def asset_classes, do: @asset_classes

  @doc "The boolean columns the instruments page can flip."
  @spec flags() :: [atom()]
  def flags, do: @flags

  @doc "The flag column named by a page event, if it is one."
  @spec flag(String.t()) :: {:ok, atom()} | :error
  def flag(name) when is_binary(name) do
    case Enum.find(@flags, &(Atom.to_string(&1) == name)) do
      nil -> :error
      flag -> {:ok, flag}
    end
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(instrument, attrs) do
    instrument
    |> cast(attrs, [
      :symbol,
      :exchange,
      :currency,
      :asset_class,
      :figi,
      :active,
      :oanda_symbol,
      :questrade_symbol,
      :questrade_symbol_id,
      :massive_ticker,
      :feed_questrade_bars,
      :feed_massive_daily,
      :feed_options_chain,
      :test_broker,
      :spread_bps
    ])
    |> update_change(:symbol, &upcase/1)
    |> update_change(:exchange, &upcase/1)
    |> update_change(:currency, &upcase/1)
    |> update_change(:oanda_symbol, &upcase/1)
    |> update_change(:questrade_symbol, &upcase/1)
    |> update_change(:massive_ticker, &upcase/1)
    |> validate_required([:symbol, :exchange, :currency, :asset_class])
    |> validate_inclusion(:asset_class, @asset_classes)
    |> validate_length(:currency, is: 3)
    |> validate_length(:symbol, max: 20)
    |> unique_constraint([:symbol, :exchange], name: :instruments_symbol_exchange_key)
    |> validate_number(:spread_bps, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:test_broker)
    |> unique_constraint(:oanda_symbol, name: :uq_instruments_oanda_symbol)
    |> unique_constraint(:questrade_symbol, name: :uq_instruments_questrade_symbol)
    |> unique_constraint(:massive_ticker, name: :uq_instruments_massive_ticker)
  end

  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(value), do: value
end
