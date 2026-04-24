defmodule Opus.Oanda.Client do
  @moduledoc """
  HTTP client for the OANDA v20 REST API.
  Used by the trade reconciler and other services that need to query OANDA directly.
  """

  @base_url Application.compile_env(:opus, :oanda_base_url, "https://api-fxpractice.oanda.com")

  def base_url, do: Application.get_env(:opus, :oanda_base_url, @base_url)
  def account_id, do: Application.fetch_env!(:opus, :oanda_account_id)
  def api_key, do: Application.fetch_env!(:opus, :oanda_api_key)

  @doc "Fetch all currently open trades from OANDA."
  def get_open_trades do
    url = "#{base_url()}/v3/accounts/#{account_id()}/openTrades"

    case http_get(url) do
      {:ok, %{"trades" => trades}} -> {:ok, trades}
      {:ok, body} -> {:ok, body["trades"] || []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch details for a single trade (open or closed) by OANDA trade ID."
  def get_trade(trade_id) do
    url = "#{base_url()}/v3/accounts/#{account_id()}/trades/#{trade_id}"

    case http_get(url) do
      {:ok, %{"trade" => trade}} -> {:ok, trade}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Close a trade. Pass units to partially close, or nil to close all."
  def close_trade(trade_id, units \\ nil) do
    url = "#{base_url()}/v3/accounts/#{account_id()}/trades/#{trade_id}/close"

    body =
      case units do
        nil -> %{}
        u -> %{"units" => to_string(u)}
      end

    case http_put(url, body) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Private HTTP helpers --

  defp http_get(url) do
    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp http_put(url, body) do
    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"}
    ]

    case Req.put(url, headers: headers, json: body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
