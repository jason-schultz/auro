defmodule Opus.Repo.Migrations.CreatePaperOptions do
  use Ecto.Migration

  @moduledoc """
  The options paper book (research/options_paper_engine.md): the wheel run
  nightly on the stored chain snapshots. One row per short option leg or
  share lot, and an append-only event log whose cash amounts, added to the
  starting cash, give the book's cash. Opus-only; Rust never reads it.
  """

  def change do
    create table(:paper_option_positions) do
      add :underlying_instrument_id, references(:instruments, type: :bigint), null: false
      # Null for a share lot.
      add :contract_id, references(:option_contracts, type: :bigint)
      # "put", "call" (short legs) or "shares".
      add :kind, :string, size: 8, null: false
      # Contracts for a leg, shares for a lot.
      add :quantity, :integer, null: false
      add :strike, :float
      add :expiration, :date
      # Premium per share for a leg, cost per share for a lot.
      add :open_price, :float, null: false
      add :opened_on, :date, null: false
      add :close_price, :float
      add :closed_on, :date
      # open, closed, expired, assigned, called_away
      add :status, :string, size: 12, null: false, default: "open"
      add :commission, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_option_positions, [:status])

    create table(:paper_option_events) do
      add :position_id, references(:paper_option_positions, type: :bigint), null: false
      add :underlying_instrument_id, references(:instruments, type: :bigint), null: false
      # The market date of the snapshot the event came from.
      add :on, :date, null: false
      # open, mark, close, expire, assign, call_away
      add :kind, :string, size: 12, null: false
      # Signed change to the book's cash, commission included.
      add :cash, :float, null: false, default: 0.0
      add :detail, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:paper_option_events, [:underlying_instrument_id, :on])
    create unique_index(:paper_option_events, [:position_id, :kind, :on])
  end
end
