defmodule Opus.Repo.Migrations.AddExecutionQualityColumnsToLiveTrades do
  use Ecto.Migration

  @moduledoc """
  Mirrors Rust's 20261017000002_live_trades_execution_quality.sql so the Opus
  test database (built from Ecto migrations only) has the columns the journal
  reads. On dev/prod Rust has already added them; add_if_not_exists is a no-op.
  """

  def up do
    alter table(:live_trades) do
      add_if_not_exists :signal_price, :float
      add_if_not_exists :expected_entry_price, :float
      add_if_not_exists :entry_spread, :float
      add_if_not_exists :expected_exit_price, :float
      add_if_not_exists :exit_spread, :float
    end
  end

  def down do
    # Rust owns these columns; leave them in place.
    :ok
  end
end
