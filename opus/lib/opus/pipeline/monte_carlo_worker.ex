defmodule Opus.Pipeline.MonteCarloWorker do
  @moduledoc """
  Executes the monte-carlo stage.

  Non-evo configs (no lineage_id in args):
    - pass → promote to live_strategies
    - fail → enqueue OllamaIterationWorker

  Evo configs (lineage_id present):
    - pass → compute + save score, insert GenerationSpawnerWorker
    - fail → insert GenerationSpawnerWorker (counts this sibling as terminal with score=0)
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{Coordinator, GenerationSpawnerWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{
        args: %{"config_id" => config_id, "depth" => depth} = args
      }) do
    lineage_id = Map.get(args, "lineage_id")
    evo_generation = Map.get(args, "evo_generation")
    evo? = not is_nil(lineage_id)

    Logger.info(
      "[Pipeline] Running monte_carlo for config #{config_id} (depth=#{depth}#{if evo?, do: ", evo gen=#{evo_generation}", else: ""})"
    )

    case Client.run_pipeline_monte_carlo(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Monte Carlo PASSED for config #{config_id} at depth=#{depth} — " <>
            "profitable_pct=#{get_in(result, ["stats", "profitable_pct"])}, " <>
            "median_sharpe=#{get_in(result, ["stats", "median_sharpe"])}, " <>
            "p95_drawdown=#{get_in(result, ["stats", "p95_drawdown"])}"
        )

        if evo? do
          GenerationSpawnerWorker.compute_and_save_score(config_id)

          {:ok, _job} =
            Oban.insert(
              GenerationSpawnerWorker.new(%{
                lineage_id: lineage_id,
                evo_generation: evo_generation
              })
            )
        else
          Coordinator.promote_to_live(config_id)
        end

        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        _stats = Map.get(result, "stats", %{})

        Logger.info("[Pipeline] Monte Carlo failed for config #{config_id}: #{reason}")

        if evo? do
          {:ok, _job} =
            Oban.insert(
              GenerationSpawnerWorker.new(%{
                lineage_id: lineage_id,
                evo_generation: evo_generation
              })
            )
        else
          :ok
          # {:ok, _job} = :ok
          # Oban.insert(
          #   OllamaIterationWorker.new(%{
          #     config_id: config_id,
          #     depth: depth,
          #     failure_reason: reason,
          #     stats: stats
          #   })
          # )
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Monte Carlo request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Monte Carlo returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_monte_carlo_response}
    end
  end
end
