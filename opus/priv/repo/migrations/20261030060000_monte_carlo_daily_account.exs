defmodule Opus.Repo.Migrations.MonteCarloDailyAccount do
  use Ecto.Migration

  @moduledoc """
  Monte Carlo now reshuffles stretches of the account's daily results
  (stationary block bootstrap, `mc_method: "daily_block_bootstrap"`), the
  account valued at each day's last bar with open trades included and every
  trade sized as live sizes it. Its `p95_drawdown` is therefore the
  account's drop at the strategy's own sizing (the backtest's
  `account_max_drawdown` basis), no longer every trade on a whole account
  added up. On that basis 35% would almost never bind (at 1% risk a 35% drop
  is dozens of stop-outs in a row), so the bar becomes 10%: a 1-in-20 bad
  run, on its own, shouldn't trip the account's 10% drawdown pause.

  `profitable_pct` keeps its 95% bar; only its wording changes (reshuffled
  daily histories, not redrawn trades).
  """

  def up do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.10,
        description = 'A bad run (1 in 20) loses at most 10% of the account at the strategy''s own sizing, open trades valued daily',
        updated_at = now()
    WHERE stage = 'monte_carlo' AND metric = 'p95_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET description = 'At least 95% of reshuffled daily account histories made money',
        updated_at = now()
    WHERE stage = 'monte_carlo' AND metric = 'profitable_pct'
    """)
  end

  def down do
    execute("""
    UPDATE validation_thresholds
    SET value = 0.35,
        description = 'A bad run (1 in 20) loses at most 35%',
        updated_at = now()
    WHERE stage = 'monte_carlo' AND metric = 'p95_drawdown'
    """)

    execute("""
    UPDATE validation_thresholds
    SET description = 'At least 95% of redrawn trade histories made money',
        updated_at = now()
    WHERE stage = 'monte_carlo' AND metric = 'profitable_pct'
    """)
  end
end
