defmodule Opus.Repo.Migrations.AddInstrumentClassToValidationThresholds do
  use Ecto.Migration

  @doc """
  Extends validation_thresholds with an instrument_class dimension so thresholds
  can be tuned per instrument type (fx_major, fx_cross, metal, commodity, index).

  Classes match Rust's `instrument_to_class()` mapping:
    fx_major  — EUR_USD, GBP_USD, USD_JPY, USD_CHF, USD_CAD, AUD_USD, NZD_USD
    fx_cross  — all other FX pairs (EUR_AUD, CAD_JPY, GBP_CAD, etc.)
    metal     — XAU_USD, XAG_USD, XPT_USD, XPD_USD, XCU_USD
    commodity — WTICO_USD, BCO_USD, NATGAS_USD, CORN_USD, WHEAT_USD, SOYBN_USD
    index     — UK100_GBP, EU50_EUR, AU200_AUD, JP225_USD, US30_USD, SPX500_USD, etc.
    all       — catch-all fallback when no specific class row exists

  Rust lookup order: try (stage, timeframe_class, instrument_class), fall back to
  (stage, timeframe_class, 'all'). This means you only need to seed overrides for
  classes that need different values — everything else hits 'all'.

  Realistic backtest sharpe targets by class (informed by overnight pipeline run):
    fx_major/cross H1 mean reversion:  0.40 (best real result: 0.41 w/ 35 trades)
    metal H1 trend following:           0.30 (best: 0.25, directionally right)
    commodity H1 trend following:       0.25 (NATGAS 330% return but 0.18 sharpe)
    index H1 either:                    0.35 (EU50 0.41 w/ 35 trades)
  """

  def up do
    # 1. Add instrument_class column — default 'all' so existing rows stay valid.
    alter table(:validation_thresholds) do
      add :instrument_class, :string, null: false, default: "all"
    end

    # 2. The existing composite PK is (stage, timeframe_class, metric).
    #    Drop it and recreate with instrument_class included.
    execute "ALTER TABLE validation_thresholds DROP CONSTRAINT validation_thresholds_pkey"

    execute """
    ALTER TABLE validation_thresholds
    ADD PRIMARY KEY (stage, timeframe_class, instrument_class, metric)
    """

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    # 3. Seed per-class overrides. Only sharpe and max_drawdown differ meaningfully
    #    by instrument class — num_trades, expectancy, and total_return use the 'all'
    #    defaults. Walk-forward and Monte Carlo gates also use 'all' defaults since
    #    the retention/robustness checks are instrument-agnostic.
    execute("""
    INSERT INTO validation_thresholds
      (stage, timeframe_class, instrument_class, metric, operator, value, description, inserted_at, updated_at)
    VALUES
      -- FX Majors: tightest pairs, mean reversion dominant, realistic H1 sharpe
      ('backtest', 'h1', 'fx_major', 'sharpe',       'gte', 0.40, 'FX major pairs H1 min Sharpe',       '#{now}', '#{now}'),
      ('backtest', 'h1', 'fx_major', 'max_drawdown',  'lte', 0.15, 'FX major pairs H1 max drawdown',     '#{now}', '#{now}'),

      -- FX Crosses: wider spreads/ranges, slightly looser drawdown tolerance
      ('backtest', 'h1', 'fx_cross', 'sharpe',       'gte', 0.40, 'FX cross pairs H1 min Sharpe',       '#{now}', '#{now}'),
      ('backtest', 'h1', 'fx_cross', 'max_drawdown',  'lte', 0.20, 'FX cross pairs H1 max drawdown',     '#{now}', '#{now}'),

      -- Metals: trend following dominant, volatile, harder to get high sharpe
      ('backtest', 'h1', 'metal',    'sharpe',       'gte', 0.30, 'Metals H1 min Sharpe',               '#{now}', '#{now}'),
      ('backtest', 'h1', 'metal',    'max_drawdown',  'lte', 0.30, 'Metals H1 max drawdown',             '#{now}', '#{now}'),
      ('backtest', 'h1', 'metal',    'num_trades',    'gte', 20,   'Metals H1 min trades (trends rarer)', '#{now}', '#{now}'),

      -- Commodities: most volatile, trend following, highest drawdown tolerance
      ('backtest', 'h1', 'commodity', 'sharpe',      'gte', 0.25, 'Commodity H1 min Sharpe',            '#{now}', '#{now}'),
      ('backtest', 'h1', 'commodity', 'max_drawdown', 'lte', 0.35, 'Commodity H1 max drawdown',          '#{now}', '#{now}'),
      ('backtest', 'h1', 'commodity', 'num_trades',   'gte', 20,   'Commodity H1 min trades',            '#{now}', '#{now}'),

      -- Indices: either strategy, moderate volatility
      ('backtest', 'h1', 'index',    'sharpe',       'gte', 0.35, 'Index H1 min Sharpe',                '#{now}', '#{now}'),
      ('backtest', 'h1', 'index',    'max_drawdown',  'lte', 0.25, 'Index H1 max drawdown',              '#{now}', '#{now}'),
      ('backtest', 'h1', 'index',    'num_trades',    'gte', 25,   'Index H1 min trades',                '#{now}', '#{now}'),

      -- Walk-forward OOS sharpe scales proportionally with backtest target
      -- (sharpe_retention 0.5 already enforces the ratio — only OOS floor differs)
      ('walk_forward', 'h1', 'fx_major',  'oos_sharpe', 'gte', 0.20, 'FX major H1 OOS min Sharpe',   '#{now}', '#{now}'),
      ('walk_forward', 'h1', 'fx_cross',  'oos_sharpe', 'gte', 0.20, 'FX cross H1 OOS min Sharpe',   '#{now}', '#{now}'),
      ('walk_forward', 'h1', 'metal',     'oos_sharpe', 'gte', 0.15, 'Metal H1 OOS min Sharpe',      '#{now}', '#{now}'),
      ('walk_forward', 'h1', 'commodity', 'oos_sharpe', 'gte', 0.12, 'Commodity H1 OOS min Sharpe',  '#{now}', '#{now}'),
      ('walk_forward', 'h1', 'index',     'oos_sharpe', 'gte', 0.17, 'Index H1 OOS min Sharpe',      '#{now}', '#{now}')
    """)
  end

  def down do
    execute "ALTER TABLE validation_thresholds DROP CONSTRAINT validation_thresholds_pkey"

    execute """
    DELETE FROM validation_thresholds WHERE instrument_class != 'all'
    """

    alter table(:validation_thresholds) do
      remove :instrument_class
    end

    execute """
    ALTER TABLE validation_thresholds
    ADD PRIMARY KEY (stage, timeframe_class, metric)
    """
  end
end
