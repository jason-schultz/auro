defmodule Opus.Trading.AccountLimits do
  @moduledoc """
  The account-level safety limits (`trading_config.account_limits`):

  - `drawdown_pause_pct`: pause every new entry when NAV falls this far
    below its peak since `since` or the last reset (`Opus.Trading.AccountPause`).
  - `risk_budget_pct`: the most of NAV at risk across open trades at once.
  - `max_open_per_group`: open trades allowed per asset class at once.
  - `since`: when the limits took effect.

  The risk budget and group cap are enforced by the engine when a trade
  opens (pushed with the rules, `Opus.Trading.RulesEngine`).
  """

  import Ecto.Query

  alias Opus.Repo

  @type t :: %{
          drawdown_pause_pct: number(),
          risk_budget_pct: number(),
          max_open_per_group: pos_integer(),
          since: DateTime.t()
        }

  @doc "The limits, or nil before the migration that sets them has run."
  @spec get() :: t() | nil
  def get do
    from(c in "trading_config", where: c.key == "account_limits", select: c.value)
    |> Repo.one()
    |> parse()
  end

  defp parse(%{
         "drawdown_pause_pct" => pause,
         "risk_budget_pct" => budget,
         "max_open_per_group" => per_group,
         "since" => since
       }) do
    {:ok, since, _} = DateTime.from_iso8601(since)

    %{
      drawdown_pause_pct: pause,
      risk_budget_pct: budget,
      max_open_per_group: per_group,
      since: since
    }
  end

  defp parse(nil), do: nil
end
