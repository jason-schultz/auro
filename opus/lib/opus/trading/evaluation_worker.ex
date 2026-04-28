defmodule Opus.Trading.EvaluationWorker do
  @moduledoc """
  Cron-scheduled worker that triggers strategy evaluation in the Auro engine.
  Fires at every H1 (`:00`) and M15 (`:00, :15, :30, :45`) boundary.
  """

  use Oban.Worker, queue: :evaluations, max_attempts: 1

  require Logger

  alias Opus.Auro.Client

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"granularity" => granularity}}) do
    target_slot = compute_target_slot(granularity, DateTime.utc_now())
    idempotency_key = "#{granularity}:#{DateTime.to_iso8601(target_slot)}"

    Logger.info("[EvaluationWorker] triggering #{granularity} eval for slot #{idempotency_key}")

    case Client.evaluate(granularity, target_slot, idempotency_key) do
      {:ok, %{"evaluated" => true, "signals" => signals} = response} ->
        log_eval_summary(granularity, response, signals)
        :ok

      {:ok, %{"evaluated" => false, "reason" => reason}} ->
        Logger.info("[EvaluationWorker] #{granularity} not evaluated: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error("[EvaluationWorker] #{granularity} eval failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compute_target_slot("H1", now) do
    %{now | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp compute_target_slot("M15", now) do
    minute = div(now.minute, 15) * 15
    %{now | minute: minute, second: 0, microsecond: {0, 0}}
  end

  defp log_eval_summary(granularity, response, signals) do
    staleness = response["staleness_candles"]
    duplicate = response["duplicate"]
    signal_count = length(signals)

    Logger.info(
      "[EvaluationWorker] #{granularity} complete: " <>
        "#{signal_count} signals, " <>
        "staleness=#{staleness}, " <>
        "duplicate=#{duplicate}"
    )

    Enum.each(signals, fn signal ->
      Logger.debug("[EvaluationWorker] signal: #{inspect(signal)}")
    end)
  end
end
