defmodule Opus.Accounts do
  @moduledoc """
  Cross-broker account overview for the accounts page.

  Balances come from the Rust engine, which owns every broker connection
  (`GET /api/brokers`, `GET /api/brokers/wealthsimple`). Opus only shapes
  them (`Opus.Accounts.Overview`); it never talks to a broker itself.
  """

  alias Opus.Accounts.Overview
  alias Opus.Auro.Client

  @spec overview() :: {:ok, Overview.t()} | {:error, term()}
  def overview do
    with {:ok, brokers} <- Client.list_brokers(),
         {:ok, wealthsimple} <- Client.wealthsimple_accounts() do
      {:ok, Overview.build(brokers, wealthsimple)}
    end
  end

  @doc "Re-price Wealthsimple positions from Questrade quotes, then rebuild the overview."
  @spec refresh() :: {:ok, Overview.t()} | {:error, term()}
  def refresh do
    with {:ok, _} <- Client.refresh_wealthsimple_prices() do
      overview()
    end
  end
end
