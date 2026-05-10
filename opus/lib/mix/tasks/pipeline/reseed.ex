defmodule Mix.Tasks.Pipeline.Reseed do
  @shortdoc "Seeds pipeline from best known params per instrument/strategy (highest backtest sharpe)"

  use Mix.Task

  import Ecto.Query

  alias Opus.Pipeline.{Coordinator, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    best_configs = fetch_best_configs()

    Mix.shell().info("Found #{length(best_configs)} instrument/strategy combos with prior backtest results\n")

    {submitted, skipped} =
      Enum.reduce(best_configs, {0, 0}, fn row, {s, sk} ->
        if already_reseeded?(row) do
          Mix.shell().info("[reseed] skip  #{row.strategy_type} #{row.instrument} (already reseeded)")
          {s, sk + 1}
        else
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
                "[reseed] #{row.strategy_type} #{row.instrument} sharpe=#{Float.round(row.sharpe, 4)} → #{config.id}"
              )
              {s + 1, sk}

            {:error, reason} ->
              Mix.shell().error(
                "[reseed] FAILED #{row.strategy_type} #{row.instrument}: #{inspect(reason)}"
              )
              {s, sk}
          end
        end
      end)

    Mix.shell().info("\nDone: #{submitted} submitted, #{skipped} skipped")
  end

  # For each (instrument, granularity, strategy_type) combo, find the config whose
  # backtest had the highest sharpe with enough trades to be meaningful.
  # Filters to num_trades >= 20 (lowest per-class minimum) to avoid seeding from
  # phantom high-sharpe results produced by tiny trade samples.
  defp fetch_best_configs do
    from(sc in StrategyConfig,
      join: se in StrategyEvaluation,
      on: se.strategy_config_id == sc.id,
      where: se.stage == "backtest",
      where: not is_nil(se.stats),
      where: fragment("(? ->> 'num_trades')::float", se.stats) >= 20,
      where: fragment("(? ->> 'expectancy')::float", se.stats) > 0.0,
      where: fragment("(? ->> 'total_return')::float", se.stats) > 0.0,
      select: %{
        instrument: sc.instrument,
        granularity: sc.granularity,
        strategy_type: sc.strategy_type,
        parameters: sc.parameters,
        sharpe: fragment("(? ->> 'sharpe')::float", se.stats)
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

  # Skip if a reseed config already exists for this combo (source="reseed", no parent).
  defp already_reseeded?(%{instrument: instrument, granularity: granularity, strategy_type: strategy_type}) do
    Repo.exists?(
      from c in StrategyConfig,
        where:
          c.instrument == ^instrument and
            c.granularity == ^granularity and
            c.strategy_type == ^strategy_type and
            c.source == "reseed" and
            is_nil(c.parent_config_id)
    )
  end
end
