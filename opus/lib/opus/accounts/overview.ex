defmodule Opus.Accounts.Overview do
  @moduledoc """
  Pure shaping of the Rust broker payloads into the accounts page model.

  Input is the JSON from `GET /api/brokers` (one entry per broker with its
  live balances) and `GET /api/brokers/wealthsimple` (accounts with their
  hand-entered positions). Output is a map the page renders directly: a
  CAD total, one row per account sorted by value with its share of the
  total, and one positions table per Wealthsimple account that has any.

  Only CAD accounts count toward the total and the allocation; a non-CAD
  account is still listed, with `share` nil.
  """

  @type account :: %{
          key: String.t(),
          label: String.t(),
          number: String.t() | nil,
          broker: String.t(),
          source: :live | :manual,
          currency: String.t(),
          cash: float() | nil,
          value: float(),
          share: float() | nil,
          rank: non_neg_integer()
        }

  @type t :: %{
          total_cad: float(),
          accounts: [account()],
          positions: [%{account: String.t(), rows: [map()], priced_at: DateTime.t() | nil}],
          offline: [%{broker: String.t(), error: String.t() | nil}]
        }

  @spec build([map()], [map()]) :: t()
  def build(brokers, wealthsimple_accounts) do
    accounts =
      brokers
      |> Enum.filter(& &1["connected"])
      |> Enum.flat_map(&broker_rows/1)
      |> Enum.sort_by(& &1.value, :desc)

    total_cad =
      accounts
      |> Enum.filter(&(&1.currency == "CAD"))
      |> Enum.map(& &1.value)
      |> Enum.sum()
      |> Kernel.*(1.0)

    accounts =
      accounts
      |> Enum.with_index()
      |> Enum.map(fn {account, index} ->
        account
        |> Map.put(:share, share(account, total_cad))
        |> Map.put(:rank, index)
      end)

    %{
      total_cad: total_cad,
      accounts: accounts,
      positions: position_tables(wealthsimple_accounts),
      offline:
        brokers
        |> Enum.reject(& &1["connected"])
        |> Enum.map(&%{broker: &1["display_name"], error: &1["error"]})
    }
  end

  defp broker_rows(%{"broker" => broker, "accounts" => accounts}) do
    Enum.map(accounts, fn account ->
      %{
        key: "#{broker}-#{account["id"]}",
        label: account["account_type"],
        number: number(broker, account),
        broker: broker_name(broker),
        source: if(broker == "wealthsimple", do: :manual, else: :live),
        currency: account["currency"],
        cash: if(broker == "wealthsimple", do: nil, else: account["cash"]),
        value: value(account)
      }
    end)
  end

  # Wealthsimple rows carry the account number inside `name` ("LIRA (WK3...)");
  # live brokers use the id as the number.
  defp number("wealthsimple", %{"name" => name}) do
    case Regex.run(~r/\((.+)\)$/, name || "") do
      [_, number] -> number
      _ -> nil
    end
  end

  defp number(_broker, %{"id" => id}), do: id

  defp broker_name("oanda"), do: "OANDA"
  defp broker_name("questrade"), do: "Questrade"
  defp broker_name("wealthsimple"), do: "Wealthsimple"
  defp broker_name(other), do: other

  defp value(%{"total_equity" => equity}) when is_number(equity), do: equity * 1.0

  defp value(account) do
    ((account["cash"] || 0) + (account["market_value"] || 0)) * 1.0
  end

  defp share(%{currency: "CAD", value: value}, total) when total > 0, do: value / total
  defp share(_account, _total), do: nil

  defp position_tables(accounts) do
    accounts
    |> Enum.reject(&(&1["positions"] in [nil, []]))
    |> Enum.map(fn account ->
      %{
        account: account["account_type"],
        rows: account["positions"] |> Enum.map(&position_row/1) |> Enum.sort_by(& &1.symbol),
        priced_at:
          account["positions"]
          |> Enum.map(&priced_at/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime, fn -> nil end)
      }
    end)
  end

  # When the position's price was last set: a Questrade re-price, or the
  # hand-entered value.
  defp priced_at(%{"updated_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp priced_at(_position), do: nil

  defp position_row(position) do
    shares = position["shares"] * 1.0
    cost = position["avg_cost"]
    price = position["current_price"] || cost

    %{
      symbol: position["symbol"],
      shares: shares,
      avg_cost: cost,
      price: price,
      value: if(price, do: shares * price),
      gain: if(price && cost, do: shares * (price - cost))
    }
  end
end
