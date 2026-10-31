defmodule Opus.Trading.ShareAlert do
  @moduledoc """
  One share alert (`Opus.Trading.ShareAlerts`): what a strategy assigned to
  a stock or ETF said on a day, and what you did about it at Wealthsimple.
  """

  use Ecto.Schema

  schema "share_alerts" do
    field :live_strategy_id, Ecto.UUID
    field :day, :date
    field :side, :string
    field :reason, :string
    field :symbol, :string
    field :currency, :string
    field :price, :float
    field :stop_price, :float
    field :shares, :float
    field :status, :string, default: "open"
    field :filled_shares, :float
    field :filled_price, :float
    field :filled_at, :utc_datetime
    field :account, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
