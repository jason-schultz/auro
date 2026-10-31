defmodule Opus.Accounts.Holdings do
  @moduledoc """
  The hand-entered Wealthsimple accounts and holdings (Wealthsimple has no
  API), edited on the Accounts page and saved through the engine
  (`PUT /api/brokers/wealthsimple`, which replaces the whole list).

  You enter each account's cash and the holdings in it; an account whose
  holdings you don't list (a managed portfolio) takes a holdings value
  instead. The latest Questrade price of each holding is kept across a save,
  so the page doesn't fall back to cost until the next re-price.

  A draft is the form's state: strings as typed, so a half-typed number
  survives a re-render.
  """

  @account_types ~w(TFSA FHSA RRSP LIRA RRIF RESP Non-registered Personal Cash Crypto)
  @currencies ~w(CAD USD)

  @type draft :: [map()]
  @type fill :: %{
          side: String.t(),
          symbol: String.t(),
          shares: float(),
          price: float(),
          cash: float()
        }

  @doc "Account types offered in the editor."
  @spec account_types() :: [String.t()]
  def account_types, do: @account_types

  @doc "Currencies offered in the editor."
  @spec currencies() :: [String.t()]
  def currencies, do: @currencies

  @doc "The editor's starting draft, from the stored accounts."
  @spec draft([map()]) :: draft()
  def draft(accounts) do
    Enum.map(accounts, fn a ->
      %{
        "account_type" => a["account_type"],
        "account_number" => a["account_number"] || "",
        "currency" => a["currency"] || "CAD",
        "cash" => text(a["cash"]),
        "market_value" => if(a["positions"] in [nil, []], do: text(a["market_value"]), else: ""),
        "positions" =>
          Enum.map(a["positions"] || [], fn p ->
            %{
              "symbol" => p["symbol"],
              "shares" => text(p["shares"]),
              "avg_cost" => text(p["avg_cost"])
            }
          end)
      }
    end)
  end

  @doc "A blank account to add to the draft."
  @spec blank_account() :: map()
  def blank_account,
    do: %{
      "account_type" => "TFSA",
      "account_number" => "",
      "currency" => "CAD",
      "cash" => "",
      "market_value" => "",
      "positions" => []
    }

  @doc "A blank holding to add to an account."
  @spec blank_position() :: map()
  def blank_position, do: %{"symbol" => "", "shares" => "", "avg_cost" => ""}

  @doc """
  The draft as the form sent it (`%{"accounts" => %{"0" => …}}`, positions
  likewise), in order.
  """
  @spec from_params(map()) :: draft()
  def from_params(%{"accounts" => accounts}) do
    accounts
    |> indexed()
    |> Enum.map(fn a ->
      a
      |> Map.take(~w(account_type account_number currency cash market_value))
      |> Map.put("positions", a |> Map.get("positions", %{}) |> indexed())
    end)
  end

  def from_params(_params), do: []

  @doc """
  A trade made by hand applied to the first account of type `account`: a
  buy adds the shares at a blended average cost, a sale takes them off
  (the holding goes when none are left); the cash moves by `fill.cash`.
  `{:error, words}` when there's no such account or the sale is more than
  the account holds.
  """
  @spec apply_fill(draft(), String.t(), fill()) :: {:ok, draft()} | {:error, String.t()}
  def apply_fill(draft, account, fill) do
    case Enum.find_index(draft, &(&1["account_type"] == account)) do
      nil ->
        {:error, "There's no #{account} account on the Accounts page."}

      i ->
        a = Enum.at(draft, i)

        with {:ok, positions} <- trade(a["positions"], fill, account) do
          cash = number(a["cash"]) + fill.cash
          {:ok, List.replace_at(draft, i, %{a | "positions" => positions, "cash" => text(cash)})}
        end
    end
  end

  defp trade(positions, %{side: "buy"} = fill, _account) do
    symbol = String.upcase(fill.symbol)

    case Enum.split_with(positions, &(String.upcase(&1["symbol"]) == symbol)) do
      {[held | _], rest} ->
        shares = number(held["shares"])
        total = shares + fill.shares
        cost = (shares * number(held["avg_cost"]) + fill.shares * fill.price) / total
        {:ok, rest ++ [%{held | "shares" => text(total), "avg_cost" => text(cost)}]}

      {[], _} ->
        {:ok,
         positions ++
           [%{"symbol" => symbol, "shares" => text(fill.shares), "avg_cost" => text(fill.price)}]}
    end
  end

  defp trade(positions, %{side: "sell"} = fill, account) do
    symbol = String.upcase(fill.symbol)
    held = Enum.find(positions, &(String.upcase(&1["symbol"]) == symbol))
    shares = if held, do: number(held["shares"]), else: 0.0

    cond do
      fill.shares > shares + 1.0e-9 ->
        {:error, "#{account} holds #{text(shares)} #{symbol}; the sale is #{text(fill.shares)}."}

      shares - fill.shares < 1.0e-9 ->
        {:ok, Enum.reject(positions, &(&1 == held))}

      true ->
        {:ok,
         Enum.map(positions, fn
           ^held -> %{held | "shares" => text(shares - fill.shares)}
           p -> p
         end)}
    end
  end

  # A draft's typed number, blank as 0.
  defp number(text) do
    case amount(text, "") do
      {:ok, n} when is_number(n) -> n
      _ -> 0.0
    end
  end

  @doc """
  What the engine saves from `draft`, or `{:error, words}` naming the first
  problem. Holdings with no symbol are dropped (an empty row left in the
  form). `stored` is the accounts as they are now, for each holding's
  latest price.
  """
  @spec payload(draft(), [map()]) :: {:ok, [map()]} | {:error, String.t()}
  def payload(draft, stored) do
    prices = prices(stored)

    draft
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {a, n}, {:ok, done} ->
      case account(a, n, prices) do
        {:ok, account} -> {:cont, {:ok, [account | done]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, accounts} -> {:ok, Enum.reverse(accounts)}
      error -> error
    end)
  end

  defp account(a, n, prices) do
    name = "Account #{n} (#{a["account_type"]})"

    with {:ok, cash} <- amount(a["cash"], "#{name}: cash"),
         {:ok, positions} <- positions(a["positions"] || [], name, prices),
         {:ok, held} <- held_value(a["market_value"], positions, name) do
      {:ok,
       %{
         account_type: a["account_type"],
         account_number: blank_to_nil(a["account_number"]),
         currency: a["currency"],
         cash: cash,
         market_value: held,
         total_equity: nil,
         positions: positions
       }}
    end
  end

  # Listed holdings make the account's value; only an account without them
  # takes a typed holdings value.
  defp held_value(_typed, [_ | _], _name), do: {:ok, nil}
  defp held_value(typed, [], name), do: amount(typed, "#{name}: holdings value")

  defp positions(rows, name, prices) do
    rows
    |> Enum.reject(&(String.trim(&1["symbol"] || "") == ""))
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, done} ->
      symbol = p["symbol"] |> String.trim() |> String.upcase()
      label = "#{name}, #{symbol}"

      with {:ok, shares} when is_number(shares) and shares > 0 <-
             amount(p["shares"], "#{label}: shares"),
           {:ok, cost} <- amount(p["avg_cost"], "#{label}: average cost") do
        position = %{
          symbol: symbol,
          shares: shares,
          avg_cost: cost,
          current_price: prices[symbol]
        }

        {:cont, {:ok, [position | done]}}
      else
        {:ok, _not_positive} -> {:halt, {:error, "#{label}: shares must be more than 0."}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end)
  end

  # Blank is no amount; anything else must read as a number (commas and a
  # dollar sign allowed).
  defp amount(text, label) do
    case text |> to_string() |> String.replace(~r/[,$\s]/, "") do
      "" ->
        {:ok, nil}

      clean ->
        case Float.parse(clean) do
          {value, ""} -> {:ok, value}
          _ -> {:error, "#{label} isn't a number: #{text}"}
        end
    end
  end

  defp prices(stored) do
    for a <- stored, p <- a["positions"] || [], is_number(p["current_price"]), into: %{} do
      {String.upcase(p["symbol"]), p["current_price"]}
    end
  end

  defp indexed(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp indexed(_other), do: []

  defp text(nil), do: ""

  defp text(n) when is_float(n),
    do: n |> Float.round(6) |> to_string() |> String.trim_trailing(".0")

  defp text(n), do: to_string(n)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end
end
