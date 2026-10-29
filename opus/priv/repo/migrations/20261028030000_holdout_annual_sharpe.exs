defmodule Opus.Repo.Migrations.HoldoutAnnualSharpe do
  use Ecto.Migration

  @moduledoc """
  The holdout's Sharpe bar of 0.3 was the October lockbox's, which meant the
  standard annual Sharpe; the pipeline compared it to a per-trade Sharpe,
  which for a strategy trading 250 times a year is about a fifteenth of the
  annual figure. So 0.3 per trade asked for roughly 4.7 a year from an
  intraday strategy and 1.3 from a daily one, and almost nothing passed.

  The engine now also records `annual_sharpe` (daily returns, ×√252, days
  out of the market counted flat), and the holdout checks that instead, at
  the same 0.3: one year can't prove an edge (the backtest's t ≥ 2 over
  years does that), so the holdout only checks the edge didn't vanish.
  """

  @description "Annual Sharpe at least 0.3 on the year kept aside: the edge did not vanish"
  @old_description "Holdout Sharpe (pre-registered lockbox bar)"

  def up do
    execute("""
    UPDATE validation_thresholds
    SET metric = 'annual_sharpe', description = '#{@description}', updated_at = now()
    WHERE stage = 'holdout' AND metric = 'sharpe'
    """)
  end

  def down do
    execute("""
    UPDATE validation_thresholds
    SET metric = 'sharpe', description = '#{@old_description}', updated_at = now()
    WHERE stage = 'holdout' AND metric = 'annual_sharpe'
    """)
  end
end
