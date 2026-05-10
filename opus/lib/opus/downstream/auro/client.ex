defmodule Opus.Auro.Client do
  @moduledoc """
  HTTP client for the Auro Rust engine.
  """
  require Logger

  import Opus.Trading.Granularity, only: [is_valid: 1]

  @base_url Application.compile_env(:opus, :auro_base_url, "http://localhost:3000")

  def base_url, do: Application.get_env(:opus, :auro_base_url, @base_url)

  @doc """
  Trigger evaluation of all strategies at the given granularity for the target slot.
  Returns `{:ok, response}` on success, or `{:error, reason}` on failure.
  Uses idempotency_key to prevent duplicate evaluations on retry.
  """
  @spec evaluate(String.t(), DateTime.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def evaluate(granularity, target_slot, idempotency_key)
      when is_valid(granularity) do
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
  Push the full rules payload to Rust. Replaces the in-memory rules cache
  atomically. Per Decision #23, this is the activation channel; the DB
  write is the persistence channel.

  Payload shape:
      %{
        rules: %{"strategy-uuid" => %{enabled: true, reason: "..."}, ...},
        computed_at: ~U[2026-05-06 ...]
      }
  """
  @spec push_rules(map()) :: {:ok, map()} | {:error, any()}
  def push_rules(payload) do
    Logger.info("[AuroClient] Pushing rules payload with #{map_size(payload.rules)} strategies")
    client() |> Req.post(url: "/api/rules", json: payload) |> handle_response()
  end

  @doc """
  Fetch indicator scalars (ADX, ATR%, MA deviation, Bollinger Bands) for an
  (instrument, granularity) pair from Rust's in-memory candle buffer.

  Periods default to standard values (ADX 14, Bollinger 20/2.0, ATR 14, MA 20)
  unless overridden via `opts`.
  """
  @spec get_indicators(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_indicators(instrument, granularity, opts \\ [])
      when is_valid(granularity) do
    params =
      opts
      |> Keyword.take([:adx_period, :bollinger_period, :bollinger_std, :atr_period, :ma_period])
      |> Enum.into(%{})

    client()
    |> Req.get(url: "/api/indicators/#{instrument}/#{granularity}", params: params)
    |> handle_response()
  end

  @doc """
  Submit a strategy config to the pipeline backtest stage.
  Rust loads the config, runs the backtest, evaluates thresholds, and writes
  the result to strategy_evaluations.

  Returns `{:ok, %{status: "passed"|"failed", stats: map, failure_reason: string|nil}}`.
  """
  @spec run_pipeline_backtest(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_backtest(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline backtest for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/backtest",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc """
  Run the walk-forward validation stage for a strategy config.
  Rust splits candles 70/30 IS/OOS, runs both, evaluates thresholds, writes result.
  """
  @spec run_pipeline_walk_forward(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_walk_forward(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline walk_forward for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/walk_forward",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc """
  Run the Monte Carlo validation stage for a strategy config.
  Rust runs the strategy once to get trades, then shuffles the PnL sequence
  10,000 times and computes: profitable_pct, median_sharpe, p95_drawdown.
  """
  @spec run_pipeline_monte_carlo(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_monte_carlo(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline monte_carlo for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/monte_carlo",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
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
