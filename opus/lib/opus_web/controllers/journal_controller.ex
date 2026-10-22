defmodule OpusWeb.JournalController do
  use OpusWeb, :controller

  alias Opus.Journal

  def kpis(conn, params) do
    with {:ok, window} <- window(params, 30) do
      json(conn, Journal.kpis(window, params))
    else
      {:error, msg} -> conn |> put_status(400) |> json(%{error: msg})
    end
  end

  @doc """
  Live fills against the fills the backtest assumed, per strategy, for trades
  entered in the window (default: last 90 days). Positive slippage = worse
  than the backtest. See `Opus.Trading.ExecutionQuality`.
  """
  def execution_quality(conn, params) do
    with {:ok, {from_ts, to_ts} = window} <- window(params, 90) do
      json(conn, %{
        from: DateTime.to_iso8601(from_ts),
        to: DateTime.to_iso8601(to_ts),
        strategies: Journal.execution_quality(window)
      })
    else
      {:error, msg} -> conn |> put_status(400) |> json(%{error: msg})
    end
  end

  @doc """
  Per-strategy performance leaderboard over the window (default: last 30 days).
  """
  def strategy_performance(conn, params) do
    with {:ok, {from_ts, to_ts} = window} <- window(params, 30) do
      json(conn, %{rows: Journal.strategy_performance(window), from: from_ts, to: to_ts})
    else
      {:error, msg} -> conn |> put_status(400) |> json(%{error: msg})
    end
  end

  # `to` defaults to now, `from` to `default_days` before `to`.
  defp window(params, default_days) do
    now = DateTime.utc_now()

    with {:ok, to_ts} <- parse_ts(Map.get(params, "to"), now),
         {:ok, from_ts} <-
           parse_ts(Map.get(params, "from"), DateTime.add(to_ts, -default_days * 86_400, :second)) do
      {:ok, {from_ts, to_ts}}
    end
  end

  defp parse_ts(nil, fallback), do: {:ok, fallback}

  defp parse_ts(value, _fallback) do
    case DateTime.from_iso8601(value) do
      {:ok, ts, _offset} -> {:ok, ts}
      _ -> {:error, "invalid timestamp: #{value}"}
    end
  end
end
