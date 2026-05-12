defmodule Opus.Pipeline.BacktestWorker do
  @moduledoc """
  Executes the backtest stage and enqueues the next stage on completion.

  Non-evo configs (no lineage_id in args):
    - pass → WalkForwardWorker
    - fail → GridIterationWorker

  Evo configs (lineage_id present):
    - pass → WalkForwardWorker (with lineage args forwarded)
    - fail → GenerationSpawnerWorker (counts this sibling as terminal)
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{GenerationSpawnerWorker, GridIterationWorker, WalkForwardWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id, "depth" => depth} = args}) do
    lineage_id = Map.get(args, "lineage_id")
    evo_generation = Map.get(args, "evo_generation")
    evo? = not is_nil(lineage_id)

    Logger.info(
      "[Pipeline] Running backtest for config #{config_id} (depth=#{depth}#{if evo?, do: ", evo gen=#{evo_generation}", else: ""})"
    )

    case Client.run_pipeline_backtest(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Backtest passed for config #{config_id} — " <>
            "sharpe=#{get_in(result, ["stats", "sharpe"])}, " <>
            "num_trades=#{get_in(result, ["stats", "num_trades"])}"
        )

        next_args = %{config_id: config_id, depth: depth}

        next_args =
          if evo?,
            do: Map.merge(next_args, %{lineage_id: lineage_id, evo_generation: evo_generation}),
            else: next_args

        {:ok, _job} = Oban.insert(WalkForwardWorker.new(next_args))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        stats = Map.get(result, "stats", %{})

        Logger.info("[Pipeline] Backtest failed for config #{config_id}: #{reason}")

        if evo? do
          {:ok, _job} =
            Oban.insert(
              GenerationSpawnerWorker.new(%{
                lineage_id: lineage_id,
                evo_generation: evo_generation
              })
            )
        else
          {:ok, _job} =
            Oban.insert(
              GridIterationWorker.new(%{
                config_id: config_id,
                depth: depth,
                failure_reason: reason,
                stats: stats
              })
            )
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Backtest request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Backtest returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_backtest_response}
    end
  end
end
