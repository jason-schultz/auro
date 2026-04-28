defmodule Opus.Auro.Client do
  @moduledoc """
  HTTP Client for the Auro Rust engine.
  """

  require Logger

  @doc """
  Trigger evaluation of all strategies at the given granularity for the target slot.

  Returns `{:ok, response}` on success, or `{:error, reason}` on failure.
  Uses idempotency_key to prevent duplicate evaluations on retry.
  """
  @spec evaluate(String.t(), DateTime.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def evaluate(granularity, target_slot, idempotency_key) when granularity in ["M15", "H1"] do
    body = %{
      target_slot: DateTime.to_iso8601(target_slot),
      idempotency_key: idempotency_key
    }

    url = "#{base_url()}/api/evaluate/#{granularity}"

    case Req.post(url, json: body, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        Logger.info("[AuroClient] Evaluation successful for #{granularity} #{target_slot}")
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.error(
          "[AuroClient] Evaluation failed with status #{status} for #{granularity} #{target_slot}: #{inspect(response_body)}"
        )

        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.error(
          "[AuroClient] Evaluation request failed for #{granularity} #{target_slot}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp base_url do
    Application.fetch_env!(:opus, :auro_base_url)
  end
end
