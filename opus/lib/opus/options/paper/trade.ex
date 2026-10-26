defmodule Opus.Options.Paper.Trade do
  @moduledoc """
  One paper trade: the legs a book opened together on one underlying (a
  wheel put or call or share lot, a put spread's two legs, an iron condor's
  four, a bought option's one), open until they all close.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @strategies ~w(wheel put_spread iron_condor ideas crash_puts)

  schema "paper_option_trades" do
    field :strategy, :string
    field :underlying_instrument_id, :integer
    field :structure, :string
    field :opened_on, :date
    field :closed_on, :date
    field :status, :string, default: "open"
    field :symbol, :string, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def strategies, do: @strategies
end
