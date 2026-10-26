defmodule Opus.Options.Paper.Position do
  @moduledoc """
  One paper position: an option leg, short or long (per-share premium, one
  or more contracts), or a share lot from an assignment (per-share cost).
  Every position belongs to a trade (`Opus.Options.Paper.Trade`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "paper_option_positions" do
    field :trade_id, :integer
    field :underlying_instrument_id, :integer
    field :contract_id, :integer
    field :side, :string, default: "short"
    field :kind, :string
    field :quantity, :integer
    field :strike, :float
    field :expiration, :date
    field :open_price, :float
    field :opened_on, :date
    field :close_price, :float
    field :closed_on, :date
    field :status, :string, default: "open"
    field :commission, :float, default: 0.0
    field :symbol, :string, virtual: true

    timestamps(type: :utc_datetime_usec)
  end
end
