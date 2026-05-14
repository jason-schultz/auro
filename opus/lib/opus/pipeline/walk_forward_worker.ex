defmodule Opus.Pipeline.WalkForwardWorker do
  @moduledoc """
  Executes the walk-forward stage and enqueues the next stage on completion.

  Non-evo configs (no lineage_id in args):
    - pass → MonteCarloWorker
    - fail → OllamaIterationWorker

  Evo configs (lineage_id present):
    - pass → MonteCarloWorker (with lineage args forwarded)
    - fail → GenerationSpawnerWorker (counts this sibling as terminal)
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{GenerationSpawnerWorker, MonteCarloWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id, "depth" => depth} = args}) do
    lineage_id = Map.get(args, "lineage_id")
    evo_generation = Map.get(args, "evo_generation")
    evo? = not is_nil(lineage_id)

    Logger.info(
      "[Pipeline] Running walk_forward for config #{config_id} (depth=#{depth}#{if evo?, do: ", evo gen=#{evo_generation}", else: ""})"
    )

    case Client.run_pipeline_walk_forward(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Walk-forward passed for config #{config_id} — " <>
            "oos_sharpe=#{get_in(result, ["stats", "oos_sharpe"])}, " <>
            "sharpe_retention=#{get_in(result, ["stats", "sharpe_retention"])}"
        )

        next_args = %{config_id: config_id, depth: depth}

        next_args =
          if evo?,
            do: Map.merge(next_args, %{lineage_id: lineage_id, evo_generation: evo_generation}),
            else: next_args

        {:ok, _job} = Oban.insert(MonteCarloWorker.new(next_args))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        _stats = Map.get(result, "stats", %{})

        Logger.info("[Pipeline] Walk-forward failed for config #{config_id}: #{reason}")

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
          # {:ok, _job} =
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
          "[Pipeline] Walk-forward request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Walk-forward returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_walk_forward_response}
    end
  end
end
