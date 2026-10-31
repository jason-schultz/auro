defmodule Opus.Accounts do
  @moduledoc """
  Cross-broker account overview for the accounts page.

  Balances come from the Rust engine, which owns every broker connection
  (`GET /api/brokers`, `GET /api/brokers/wealthsimple`). Opus only shapes
  them (`Opus.Accounts.Overview`); it never talks to a broker itself.
  """

  alias Opus.Accounts.{Holdings, Overview}
  alias Opus.Auro.Client
  alias Opus.Instruments

  @spec overview() :: {:ok, Overview.t()} | {:error, term()}
  def overview do
    with {:ok, brokers} <- Client.list_brokers(),
         {:ok, wealthsimple} <- Client.wealthsimple_accounts() do
      {:ok, Overview.build(brokers, wealthsimple)}
    end
  end

  @doc """
  Save the hand-entered Wealthsimple accounts and holdings from the
  editor's draft (`Opus.Accounts.Holdings`), then rebuild the overview.
  `{:error, words}` when the draft doesn't read.
  """
  @spec save_holdings(Holdings.draft()) ::
          {:ok, Overview.t(), [String.t()]} | {:error, term()}
  def save_holdings(draft) do
    with {:ok, stored} <- Client.wealthsimple_accounts(),
         {:ok, payload} <- Holdings.payload(draft, stored),
         added = track(payload),
         {:ok, _saved} <- Client.save_wealthsimple_accounts(payload),
         {:ok, overview} <- overview() do
      {:ok, overview, added}
    end
  end

  @doc """
  A trade you made by hand at Wealthsimple (a logged share alert,
  `Opus.Trading.ShareAlerts.log_fill/2`) applied to the hand-entered
  account of type `account`: its holding and cash change
  (`Holdings.apply_fill/3`), then it's saved like an edit.
  """
  @spec apply_fill(String.t(), Holdings.fill()) ::
          {:ok, Overview.t(), [String.t()]} | {:error, term()}
  def apply_fill(account, fill) do
    with {:ok, stored} <- Client.wealthsimple_accounts(),
         {:ok, draft} <- stored |> Holdings.draft() |> Holdings.apply_fill(account, fill) do
      save_holdings(draft)
    end
  end

  @doc "The hand-entered Wealthsimple accounts' types, as the Log trade form offers them."
  @spec wealthsimple_account_types() :: {:ok, [String.t()]} | {:error, term()}
  def wealthsimple_account_types do
    with {:ok, stored} <- Client.wealthsimple_accounts() do
      {:ok, stored |> Enum.map(& &1["account_type"]) |> Enum.uniq()}
    end
  end

  @doc """
  A holding is fed (re-priced, its bars stored, its history and dividends
  loaded) through its instruments row, which the engine links when it
  saves the holding: adds any symbol in `payload` (`Holdings.payload/2`)
  not there yet, as a stock (the Instruments page can change it to an
  ETF). Returns the symbols added.
  """
  @spec track([map()]) :: [String.t()]
  def track(payload) do
    payload
    |> Enum.flat_map(& &1.positions)
    |> Enum.map(& &1.symbol)
    |> Enum.uniq()
    |> Enum.reject(&Instruments.known?/1)
    |> Enum.filter(&match?({:ok, _}, Instruments.add(&1, "equity")))
  end

  @doc "Re-price Wealthsimple positions from Questrade quotes, then rebuild the overview."
  @spec refresh() :: {:ok, Overview.t()} | {:error, term()}
  def refresh do
    with {:ok, _} <- Client.refresh_wealthsimple_prices() do
      overview()
    end
  end
end
