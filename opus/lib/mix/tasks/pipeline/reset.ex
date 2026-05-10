defmodule Mix.Tasks.Pipeline.Reset do
  @shortdoc "Wipe all pipeline data and reseed from best-known params (min trades filter applied)"

  use Mix.Task

  import Ecto.Query

  alias Opus.Pipeline.{Coordinator, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  @min_trades 20

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("=== Pipeline Reset ===\n")

    # Step 1 — capture best qualifying configs before we wipe anything.
    Mix.shell().info("Step 1: Capturing best configs with >= #{@min_trades} trades...")
    best = fetch_best_configs_with_trades()

    if Enum.empty?(best) do
      Mix.shell().info("  No qualifying configs found — will fall back to pipeline.seed after reset.\n")
    else
      Mix.shell().info("  Found #{length(best)} configs to reseed from.\n")
    end

    # Step 2 — truncate pipeline state.
    Mix.shell().info("Step 2: Truncating pipeline tables and queued jobs...")
    truncate_all()
    Mix.shell().info("  Done.\n")

    # Step 3 — reseed.
    if Enum.empty?(best) do
      Mix.shell().info("Step 3: No prior data — running pipeline.seed instead.")
      Mix.Task.run("pipeline.seed")
    else
      Mix.shell().info("Step 3: Reseeding from #{length(best)} captured configs...")
      reseed(best)
    end

    Mix.shell().info("\n=== Reset complete ===")
  end

  # ---------------------------------------------------------------------------

  defp fetch_best_configs_with_trades do
    from(sc in StrategyConfig,
      join: se in StrategyEvaluation,
      on: se.strategy_config_id == sc.id,
      where: se.stage == "backtest",
      where: not is_nil(se.stats),
      where: fragment("(? ->> 'num_trades')::float", se.stats) >= @min_trades,
      where: fragment("(? ->> 'expectancy')::float", se.stats) > 0.0,
      where: fragment("(? ->> 'total_return')::float", se.stats) > 0.0,
      select: %{
        instrument: sc.instrument,
        granularity: sc.granularity,
        strategy_type: sc.strategy_type,
        parameters: sc.parameters,
        sharpe: fragment("(? ->> 'sharpe')::float", se.stats),
        num_trades: fragment("(? ->> 'num_trades')::float", se.stats)
      },
      distinct: [sc.instrument, sc.granularity, sc.strategy_type],
      order_by: [
        asc: sc.instrument,
        asc: sc.granularity,
        asc: sc.strategy_type,
        desc: fragment("(? ->> 'sharpe')::float", se.stats)
      ]
    )
    |> Repo.all()
  end

  defp truncate_all do
    Repo.transaction(fn ->
      Repo.query!("TRUNCATE strategy_evaluations")
      Repo.query!("TRUNCATE strategy_configs")
      Repo.query!(
        "DELETE FROM oban_jobs WHERE queue IN ('pipeline', 'ollama') AND state != 'completed'"
      )
    end)
  end

  defp reseed(configs) do
    {submitted, failed} =
      Enum.reduce(configs, {0, 0}, fn row, {s, f} ->
        attrs = %{
          instrument: row.instrument,
          granularity: row.granularity,
          strategy_type: row.strategy_type,
          parameters: row.parameters,
          source: "reseed"
        }

        case Coordinator.submit_config(attrs) do
          {:ok, config} ->
            Mix.shell().info(
              "  [seed] #{row.strategy_type} #{row.instrument} " <>
                "sharpe=#{Float.round(row.sharpe, 4)} trades=#{round(row.num_trades)} → #{config.id}"
            )
            {s + 1, f}

          {:error, reason} ->
            Mix.shell().error(
              "  [FAIL] #{row.strategy_type} #{row.instrument}: #{inspect(reason)}"
            )
            {s, f + 1}
        end
      end)

    Mix.shell().info("\n  Submitted: #{submitted}, Failed: #{failed}")
  end
end
