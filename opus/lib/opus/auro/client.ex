defmodule Opus.Auro.Client do
  @moduledoc """
  HTTP client for the Auro Rust engine.
  """
  require Logger

  @base_url Application.compile_env(:opus, :auro_base_url, "http://localhost:3000")

  def base_url, do: Application.get_env(:opus, :auro_base_url, @base_url)

  @doc """
  Trigger evaluation of all strategies at the given granularity for the target slot.
  Returns `{:ok, response}` on success, or `{:error, reason}` on failure.
  Uses idempotency_key to prevent duplicate evaluations on retry.
  """
  @spec evaluate(String.t(), DateTime.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def evaluate(granularity, target_slot, idempotency_key) when granularity in ["M15", "H1"] do
    Logger.info(
      "[AuroClient] Triggering evaluation for #{granularity} #{target_slot} with idempotency key #{idempotency_key}"
    )

    body = %{
      target_slot: DateTime.to_iso8601(target_slot),
      idempotency_key: idempotency_key
    }

    client()
    |> Req.post(url: "/api/evaluate/#{granularity}", json: body, receive_timeout: 30_000)
    |> handle_response()
  end

  @doc """
  Remove a trade from Rust's in-memory open_positions map.

  Called by the reconciler after detecting an OANDA-side close, to keep
  Rust's in-memory state in sync. Idempotent on the Rust side — removing
  an absent key is a no-op success.
  """
  @spec delete_position(String.t() | integer()) :: {:ok, map()} | {:error, any()}
  def delete_position(trade_id) do
    Logger.info("[AuroClient] Deleting position for trade #{trade_id} from Auro")

    client()
    |> Req.delete(url: "/api/positions/#{trade_id}")
    |> handle_response()
  end

  @doc """
  Fetch indicator scalars (ADX, ATR%, MA deviation, Bollinger Bands) for an
  (instrument, granularity) pair from Rust's in-memory candle buffer.

  Periods default to standard values (ADX 14, Bollinger 20/2.0, ATR 14, MA 20)
  unless overridden via `opts`.
  """
  @spec get_indicators(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_indicators(instrument, granularity, opts \\ []) when granularity in ["M15", "H1"] do
    params =
      opts
      |> Keyword.take([:adx_period, :bollinger_period, :bollinger_std, :atr_period, :ma_period])
      |> Enum.into(%{})

    client()
    |> Req.get(url: "/api/indicators/#{instrument}/#{granularity}", params: params)
    |> handle_response()
  end

  # -- Private --

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    Logger.info("[AuroClient] Request succeeded: #{inspect(body)}")
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("[AuroClient] Request failed with status #{status}: #{inspect(body)}")
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.error("[AuroClient] Request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp client do
    Req.new(
      base_url: base_url(),
      headers: [{"Content-Type", "application/json"}]
    )
  end
end
