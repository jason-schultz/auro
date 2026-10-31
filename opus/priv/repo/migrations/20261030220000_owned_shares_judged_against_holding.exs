defmodule Opus.Repo.Migrations.OwnedSharesJudgedAgainstHolding do
  use Ecto.Migration

  @moduledoc """
  Shares held outright in a cash account (the `owned_shares` class: every
  market's broker charges no overnight cost, i.e. Wealthsimple ETFs) are
  judged in Monte Carlo against just holding the same funds over the same
  years, not the fixed 10% bad-run cap set for leveraged CFDs. Holding SPY
  through 2008 fell ~55%; a flat 10% fails a long-only ETF book for being
  an ETF book.

  For that class only:
  - `p95_drawdown` is `off` (the engine drops a most-specific `off` row).
  - `p95_drawdown_vs_hold` <= 1: the rule's daily account, scaled to swing
    as much as holding, has a 95th-percentile bad run no worse than
    holding's actual worst drop.
  - `sharpe_vs_hold` >= 0: its Sharpe (account valued daily) at least
    holding's: otherwise why trade it instead of holding.
  `profitable_pct` >= 0.95 still applies to every class. RULES_VERSION 2.
  """

  @timeframes ~w(M1 M5 M15 H1 H4)

  def up do
    for tf <- @timeframes do
      for {metric, operator, value, description} <- [
            {"p95_drawdown", "off", 0.0,
             "Owned shares: no fixed cap; judged against just holding instead"},
            {"p95_drawdown_vs_hold", "lte", 1.0,
             "Bad run, at the risk of just holding, no worse than the worst drop of holding"},
            {"sharpe_vs_hold", "gte", 0.0, "Sharpe at least that of just holding"}
          ] do
        execute """
        INSERT INTO validation_thresholds
          (stage, timeframe_class, metric, operator, value, description,
           instrument_class, strategy_type, inserted_at, updated_at)
        VALUES ('monte_carlo', '#{tf}', '#{metric}', '#{operator}', #{value},
                '#{description}', 'owned_shares', 'all', now(), now())
        """
      end
    end
  end

  def down do
    execute "DELETE FROM validation_thresholds WHERE instrument_class = 'owned_shares'"
  end
end
