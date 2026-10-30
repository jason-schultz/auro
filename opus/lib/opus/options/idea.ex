defmodule Opus.Options.Idea do
  @moduledoc """
  One option the nightly scan flagged: which list it came from (`dip_buy`
  or `cheap_vol`), the contract, the quote and model numbers the page shows,
  and the status the user gives it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @lists ~w(dip_buy cheap_vol)
  @statuses ~w(new dismissed taken)

  schema "option_ideas" do
    field :scanned_on, :date
    field :list, :string
    field :underlying_instrument_id, :integer
    field :contract_id, :integer
    field :kind, :string
    field :strike, :float
    field :expiration, :date
    field :dte, :integer
    field :spot, :float
    field :bid, :float
    field :ask, :float
    field :delta, :float
    field :open_interest, :integer
    field :spread_pct, :float
    field :iv_pct, :float
    field :rv_pct, :float
    field :iv_rv, :float
    field :breakeven, :float
    field :breakeven_move_pct, :float
    field :expected_move_pct, :float
    field :probability_profit, :float
    field :lottery, :boolean, default: false
    field :setup, :string
    field :score, :float, default: 0.0
    field :status, :string, default: "new"
    field :symbol, :string, virtual: true
    # When the chain snapshot the scan read was taken (`Opus.Options.latest_ideas/0`).
    field :chain_at, :naive_datetime_usec, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def lists, do: @lists
  def statuses, do: @statuses

  @spec status_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def status_changeset(idea, status) do
    idea
    |> change(status: status)
    |> validate_inclusion(:status, @statuses)
  end
end
