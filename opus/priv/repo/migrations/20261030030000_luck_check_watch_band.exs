defmodule Opus.Repo.Migrations.LuckCheckWatchBand do
  use Ecto.Migration

  @moduledoc """
  The luck check (walk-forward `deflated_sharpe`) passes from 80% instead of
  95%. 95% and up is a clean pass; 80–95% passes with a flag to watch it
  (the strategy page says so); under 80% fails. The owner's call (Oct 30):
  80% sure it isn't luck is worth trading on practice money and watching,
  not benching.
  """

  def up do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.80,
        description = 'At least an 80% chance the Sharpe isn''t luck from trying the same idea on many markets (95% or more is a clean pass; below that, watch it)',
        updated_at = now()
    WHERE stage = 'walk_forward' AND metric = 'deflated_sharpe'
    """)
  end

  def down do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.95,
        description = 'At least a 95% chance the Sharpe isn''t luck from trying many versions of the same idea',
        updated_at = now()
    WHERE stage = 'walk_forward' AND metric = 'deflated_sharpe'
    """)
  end
end
