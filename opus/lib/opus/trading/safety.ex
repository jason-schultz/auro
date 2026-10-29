defmodule Opus.Trading.Safety do
  @moduledoc """
  Where each account safety rule stands right now, for the Safety page:
  how far the account is below its peak, how much of the risk budget open
  trades use, how full each group is, and each switched-on strategy's
  losing streak and recent losses against the circuit breaker.

  Everything comes from Opus's own tables, so the page stands without the
  engine.
  """

  import Ecto.Query

  alias Opus.Repo

  alias Opus.Trading.{
    AccountLimits,
    AccountPause,
    CircuitBreaker,
    LiveStrategy,
    LiveTrade,
    Strategies
  }

  @doc "The limits and where each rule stands; nil before the limits exist."
  @spec overview() :: map() | nil
  def overview do
    case AccountLimits.get() do
      nil -> nil
      limits -> overview(limits)
    end
  end

  defp overview(limits) do
    rows = Strategies.list()
    enabled = Enum.filter(rows, & &1.enabled)
    open = open_trades()

    groups =
      AccountLimits.groups(Enum.map(enabled, & &1.instrument) ++ Enum.map(open, & &1.instrument))

    %{
      limits: limits,
      pause: AccountPause.open(),
      drawdown: AccountPause.standing(),
      risk: %{
        used: Enum.sum_by(open, &AccountLimits.counted_risk(&1.sizing)) / 1,
        trades: length(open),
        budget: limits.risk_budget_pct / 100,
        per_strategy:
          Enum.map(
            enabled,
            &%{instrument: &1.instrument, risk: AccountLimits.counted_risk(&1.sizing_params)}
          ),
        all_at_once: Enum.sum_by(enabled, &AccountLimits.counted_risk(&1.sizing_params)) / 1
      },
      groups: group_rows(enabled, open, groups),
      breakers:
        Enum.map(enabled, fn row ->
          Map.merge(row, CircuitBreaker.standing(row.id, limits))
        end),
      min_trades: CircuitBreaker.min_trades(),
      changes: AccountLimits.changes()
    }
  end

  defp open_trades do
    from(t in LiveTrade,
      join: s in LiveStrategy,
      on: s.id == t.live_strategy_id,
      where: t.status == "open",
      select: %{instrument: t.instrument, sizing: s.sizing}
    )
    |> Repo.all()
  end

  # One row per group a switched-on strategy trades in: how many trades are
  # open in it and which instruments belong to it.
  defp group_rows(enabled, open, groups) do
    group_of = &Map.get(groups, &1, &1)

    enabled
    |> Enum.group_by(&group_of.(&1.instrument), & &1.instrument)
    |> Enum.map(fn {group, instruments} ->
      %{
        group: group,
        instruments: instruments |> Enum.uniq() |> Enum.sort(),
        open: Enum.count(open, &(group_of.(&1.instrument) == group))
      }
    end)
    |> Enum.sort_by(&{-&1.open, &1.group})
  end
end
