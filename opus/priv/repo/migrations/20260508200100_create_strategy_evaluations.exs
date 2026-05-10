defmodule Opus.Repo.Migrations.CreateStrategyEvaluations do
  use Ecto.Migration

  @doc """
  One row per (strategy_config, stage) — records the result of each validation
  gate (backtest, walk_forward, monte_carlo) as Rust processes the config.

  status lifecycle: pending -> running -> passed | failed

  Rust writes the stats jsonb and flips status to passed/failed when done.
  Opus polls this table to advance the pipeline to the next stage.

  stats jsonb shape (set by Rust, read by Opus):
    backtest:      { sharpe, max_drawdown, num_trades, win_rate, total_return, expectancy }
    walk_forward:  { oos_sharpe, oos_return, oos_num_trades, sharpe_retention }
    monte_carlo:   { profitable_pct, median_sharpe, p95_drawdown }

  failure_reason is a human-readable string passed back to Ollama for the next
  iteration prompt — include which metric failed and by how much.
  """
  def change do
    create table(:strategy_evaluations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :strategy_config_id, :binary_id, null: false
      add :stage, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :stats, :map
      add :failure_reason, :text
      add :evaluated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:strategy_evaluations, [:strategy_config_id])
    create unique_index(:strategy_evaluations, [:strategy_config_id, :stage])
  end
end
