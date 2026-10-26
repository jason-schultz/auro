defmodule Opus.Options.Paper.Event do
  @moduledoc """
  One entry in the paper book's append-only log: an open, nightly mark,
  close, expiry, assignment or call-away, with its signed cash change and
  the book (`strategy`) whose cash it moves.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "paper_option_events" do
    field :position_id, :integer
    field :strategy, :string, default: "wheel"
    field :underlying_instrument_id, :integer
    field :on, :date
    field :kind, :string
    field :cash, :float, default: 0.0
    field :detail, :map, default: %{}
    field :symbol, :string, virtual: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
