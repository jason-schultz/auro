defmodule Opus.Repo.Migrations.CreateOptionIdeas do
  use Ecto.Migration

  @moduledoc """
  Nightly option ideas: what the scan over the stored chains found worth a
  look, one row per contract per list per night, with the numbers the page
  shows and a status the user sets. Opus-only; Rust never reads it.
  """

  def change do
    create table(:option_ideas) do
      add :scanned_on, :date, null: false
      add :list, :string, size: 16, null: false
      add :underlying_instrument_id, references(:instruments, type: :bigint), null: false
      add :contract_id, references(:option_contracts, type: :bigint), null: false
      add :kind, :string, size: 4, null: false
      add :strike, :float, null: false
      add :expiration, :date, null: false
      add :dte, :integer, null: false
      add :spot, :float, null: false
      add :bid, :float
      add :ask, :float
      add :delta, :float
      add :open_interest, :integer
      add :spread_pct, :float
      add :iv_pct, :float
      add :rv_pct, :float
      add :iv_rv, :float
      add :breakeven, :float
      add :breakeven_move_pct, :float
      add :expected_move_pct, :float
      add :probability_profit, :float
      add :lottery, :boolean, null: false, default: false
      add :setup, :text, null: false
      add :score, :float, null: false, default: 0.0
      add :status, :string, size: 12, null: false, default: "new"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:option_ideas, [:scanned_on, :list, :contract_id])
    create index(:option_ideas, [:scanned_on])
  end
end
