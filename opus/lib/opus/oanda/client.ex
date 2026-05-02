defmodule Opus.Oanda.Client do
  @moduledoc """
  HTTP client for the OANDA v20 REST API.
  Used by the trade reconciler and other services that need to query OANDA directly.
  """

  require Logger

  @base_url Application.compile_env(:opus, :oanda_base_url, "https://api-fxpractice.oanda.com")

  def base_url, do: Application.get_env(:opus, :oanda_base_url, @base_url)
  def account_id, do: Application.fetch_env!(:opus, :oanda_account_id)
  def api_key, do: Application.fetch_env!(:opus, :oanda_api_key)

  @doc "Fetch all currently open trades from OANDA."
  def get_open_trades do
    Logger.info("[OandaClient] Fetching open trades from OANDA")

    case client()
         |> Req.get(url: "/v3/accounts/#{account_id()}/openTrades")
         |> handle_response() do
      {:ok, %{"trades" => trades}} -> {:ok, trades}
      {:ok, body} -> {:ok, body["trades"] || []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch details for a single trade (open or closed) by OANDA trade ID."
  def get_trade(trade_id) do
    Logger.info("[OandaClient] Fetching details for trade #{trade_id} from OANDA")

    case client()
         |> Req.get(url: "/v3/accounts/#{account_id()}/trades/#{trade_id}")
         |> handle_response() do
      {:ok, %{"trade" => trade}} -> {:ok, trade}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Close a trade. Pass units to partially close, or nil to close all."
  def close_trade(trade_id, units \\ nil) do
    Logger.info("[OandaClient] Closing trade #{trade_id} on OANDA with units=#{units || "ALL"}")

    body =
      case units do
        nil -> %{}
        u -> %{"units" => to_string(u)}
      end

    client()
    |> Req.put(url: "/v3/accounts/#{account_id()}/trades/#{trade_id}/close", json: body)
    |> handle_response()
  end

  # -- Private --

  defp client do
    Req.new(
      base_url: base_url(),
      headers: [
        {"Authorization", "Bearer #{api_key()}"},
        {"Content-Type", "application/json"}
      ]
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    Logger.info("[OandaClient] Request succeeded with status #{status}: #{inspect(body)}")
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("[OandaClient] Request failed with status #{status}: #{inspect(body)}")
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.error("[OandaClient] Request failed: #{inspect(reason)}")
    {:error, reason}
  end
end
