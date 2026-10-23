defmodule Opus.Options do
  @moduledoc """
  Options what-if for the options page.

  The page collects a single-leg position as typed; this module turns the
  strings into the engine's request and hands back the engine's analysis
  (`POST /api/options/scenarios`). All option math lives in Rust.
  """

  alias Opus.Auro.Client

  @strategies [
    {"cash_secured_put", "Sell a put (cash-secured)", "put", "sell"},
    {"covered_call", "Sell a call (covered)", "call", "sell"},
    {"long_call", "Buy a call", "call", "buy"},
    {"long_put", "Buy a put", "put", "buy"}
  ]

  @doc "Select options for the form: `{label, value}`."
  @spec strategy_options() :: [{String.t(), String.t()}]
  def strategy_options, do: for({value, label, _, _} <- @strategies, do: {label, value})

  @doc """
  Analyse the position described by the form params (string keys, string
  values as typed). Returns the engine's analysis map or a reason the page
  can show.
  """
  @spec scenarios(map()) :: {:ok, map()} | {:error, term()}
  def scenarios(params) when is_map(params) do
    with {:ok, request} <- build_request(params) do
      Client.option_scenarios(request)
    end
  end

  @doc false
  @spec build_request(map()) :: {:ok, map()} | {:error, String.t()}
  def build_request(params) do
    with {:ok, {kind, side}} <- strategy(params["strategy"]),
         {:ok, underlying} <- required_text(params["underlying"], "Underlying"),
         {:ok, strike} <- required_number(params["strike"], "Strike"),
         {:ok, premium} <- required_number(params["premium"], "Premium"),
         {:ok, expiration} <- required_date(params["expiration"]),
         {:ok, contracts} <- optional_number(params["contracts"], "Contracts"),
         {:ok, spot} <- optional_number(params["spot"], "Spot"),
         {:ok, sigma_pct} <- optional_number(params["sigma"], "Volatility"),
         {:ok, cost_basis} <- optional_number(params["cost_basis"], "Cost basis") do
      request =
        %{
          underlying: underlying,
          kind: kind,
          side: side,
          strike: strike,
          premium: premium,
          expiration: Date.to_iso8601(expiration),
          contracts: contracts || 1.0
        }
        |> maybe_put(:spot, spot)
        |> maybe_put(:sigma, sigma_pct && sigma_pct / 100)
        |> maybe_put(:cost_basis, cost_basis)

      {:ok, request}
    end
  end

  defp strategy(value) do
    case Enum.find(@strategies, &(elem(&1, 0) == value)) do
      {_, _, kind, side} -> {:ok, {kind, side}}
      nil -> {:error, "Pick a strategy."}
    end
  end

  defp required_text(value, label) do
    case value && String.trim(value) do
      text when is_binary(text) and text != "" -> {:ok, String.upcase(text)}
      _ -> {:error, "#{label} is required."}
    end
  end

  defp required_number(value, label) do
    case optional_number(value, label) do
      {:ok, nil} -> {:error, "#{label} is required."}
      other -> other
    end
  end

  defp optional_number(nil, _label), do: {:ok, nil}

  defp optional_number(value, label) when is_binary(value) do
    case value |> String.trim() |> String.replace(["$", ",", "%"], "") do
      "" ->
        {:ok, nil}

      text ->
        case Float.parse(text) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, "#{label} must be a positive number."}
        end
    end
  end

  defp required_date(value) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "Expiration must be a date."}
    end
  end

  defp required_date(_), do: {:error, "Expiration is required."}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
