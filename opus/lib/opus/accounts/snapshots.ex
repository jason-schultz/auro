defmodule Opus.Accounts.Snapshots do
  @moduledoc """
  Net worth's history (`take_accounts/2`, `net_worth/1`): every broker
  account's value at each trading day's close, as the Accounts page counts
  it; and the hand-entered Wealthsimple holdings' history: each close
  (`take/1`, from `Opus.Accounts.SnapshotWorker`) as one row per holding
  in `holding_snapshots`, and what that history says: the value each day,
  the day's move, the worst fall from a high (`history/1`, `summary/1`).

  Only listed holdings (symbol, shares, price) are kept: an account typed
  as one holdings value doesn't move on its own.
  """

  import Ecto.Query

  alias Opus.Repo

  @doc """
  Records each real account of an overview (`Opus.Accounts.Overview`) at
  its value as `on`'s close; paper accounts aren't net worth (OANDA's
  practice account has its own history in `account_snapshots`). Returns
  the rows.
  """
  @spec take_accounts(Date.t(), [map()]) :: non_neg_integer()
  def take_accounts(on, accounts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for a <- accounts, is_number(a.value), not a.paper do
        %{
          on: on,
          broker: a.broker,
          account: a.key,
          label: a.label,
          currency: a.currency,
          value: a.value / 1,
          inserted_at: now
        }
      end

    {count, _} =
      Repo.insert_all("account_values", rows,
        on_conflict: {:replace, [:label, :currency, :value]},
        conflict_target: [:on, :account]
      )

    count
  end

  @doc """
  Net worth in CAD at each recorded close over the last `days` days, oldest
  first: `%{on, value}`, the CAD accounts added up as the Accounts page's
  total is. (Paper books aren't accounts: they're left out.)
  """
  @spec net_worth(pos_integer()) :: [%{on: Date.t(), value: float()}]
  def net_worth(days \\ 365) do
    since = Date.add(Opus.Clock.today(), -days)

    from(v in "account_values",
      where: v.on >= ^since and v.currency == "CAD",
      group_by: v.on,
      order_by: v.on,
      select: %{on: v.on, value: sum(v.value)}
    )
    |> Repo.all()
  end

  @doc "Records every listed holding at its latest price as `on`'s close. Returns the rows."
  @spec take(Date.t()) :: non_neg_integer()
  def take(on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      from(p in "wealthsimple_positions",
        join: a in "wealthsimple_accounts",
        on: a.id == p.account_id,
        where: p.shares > 0 and not is_nil(p.current_price),
        select: %{
          account_type: a.account_type,
          symbol: p.symbol,
          shares: p.shares,
          avg_cost: p.avg_cost,
          price: p.current_price
        }
      )
      |> Repo.all()
      |> Enum.map(&Map.merge(&1, %{on: on, inserted_at: now}))

    {count, _} =
      Repo.insert_all("holding_snapshots", rows,
        on_conflict: {:replace, [:shares, :avg_cost, :price]},
        conflict_target: [:on, :account_type, :symbol]
      )

    count
  end

  @doc """
  The holdings' value at each recorded close over the last `days` days,
  oldest first: `%{on, value, cost}` (cost: shares × average cost, where
  known).
  """
  @spec history(pos_integer()) :: [%{on: Date.t(), value: float(), cost: float()}]
  def history(days \\ 90) do
    since = Date.add(Opus.Clock.today(), -days)

    from(s in "holding_snapshots",
      where: s.on >= ^since,
      group_by: s.on,
      order_by: s.on,
      select: %{
        on: s.on,
        value: sum(s.shares * s.price),
        cost: sum(s.shares * coalesce(s.avg_cost, 0.0))
      }
    )
    |> Repo.all()
  end

  @doc """
  What a history (`history/1`) says: the latest value and its move on the
  day before it, and the fall from the highest close (now, and the worst).
  Nil without two closes.
  """
  @spec summary([map()]) :: map() | nil
  def summary([_, _ | _] = history) do
    [previous, latest] = Enum.take(history, -2)

    {peak, worst} =
      Enum.reduce(history, {0.0, 0.0}, fn %{value: v}, {peak, worst} ->
        peak = max(peak, v)
        {peak, max(worst, if(peak > 0, do: 1 - v / peak, else: 0.0))}
      end)

    %{
      on: latest.on,
      value: latest.value,
      day_change: latest.value - previous.value,
      day_pct: if(previous.value > 0, do: latest.value / previous.value - 1),
      drawdown: if(peak > 0, do: 1 - latest.value / peak, else: 0.0),
      worst_drawdown: worst
    }
  end

  def summary(_history), do: nil

  @doc "The holdings' move from the last close before `date` to the latest, or nil."
  @spec change_since(Date.t()) :: %{value: float(), change: float(), pct: float() | nil} | nil
  def change_since(date) do
    history = history(400)
    before = history |> Enum.filter(&(Date.compare(&1.on, date) == :lt)) |> List.last()

    case {before, List.last(history)} do
      {%{value: from}, %{value: to}} ->
        %{value: to, change: to - from, pct: if(from > 0, do: to / from - 1)}

      _ ->
        nil
    end
  end
end
