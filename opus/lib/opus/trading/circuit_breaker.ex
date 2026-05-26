defmodule Opus.Trading.CircuitBreaker do
  @moduledoc """
  Per-strategy circuit breaker that suspends live strategies on loss patterns.
  """

  use GenServer
  require Logger

  alias Opus.Repo
  alias Opus.Trading.LiveStrategy
  alias Opus.Trading.LiveTrade
  alias Opus.Trading.RulesEngine
  alias Opus.Trading.Suspension
  alias Opus.Support.Polling

  import Ecto.Query

  @poll_interval :timer.minutes(20)
  @initial_delay :timer.seconds(30)
  @rolling_window_days 30
  @rolling_min_sample 5

  @thresholds %{
    "trend_following" => %{consecutive_losses: 5, rolling_drawdown_pct: -8.0},
    "mean_reversion" => %{consecutive_losses: 7, rolling_drawdown_pct: -10.0}
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec recompute() :: :ok
  def recompute do
    GenServer.cast(__MODULE__, :recompute)
  end

  @spec last_run() :: DateTime.t() | nil
  def last_run do
    GenServer.call(__MODULE__, :last_run)
  end

  @doc "Runs one circuit-breaker evaluation cycle immediately."
  @spec run_cycle() :: %{evaluated: non_neg_integer(), triggered: non_neg_integer()}
  def run_cycle do
    strategies = list_enabled_strategies()
    open_ids = open_suspension_ids(strategies)
    candidates = Enum.reject(strategies, &MapSet.member?(open_ids, &1.id))
    stats = precompute_stats(candidates)

    triggered =
      candidates
      |> Enum.reduce(0, fn strategy, acc ->
        case maybe_suspend(strategy, stats) do
          :inserted -> acc + 1
          _ -> acc
        end
      end)

    if triggered > 0 do
      RulesEngine.recompute()
    end

    %{evaluated: length(strategies), triggered: triggered}
  end

  @impl true
  def init(_opts) do
    Logger.info("[CircuitBreaker] Started (#{div(@poll_interval, 60_000)}min poll interval)")

    Polling.schedule(self(), @initial_delay)
    {:ok, %{last_run: nil, poll_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = apply_cycle(state)
    Polling.schedule(self(), @poll_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:recompute, state) do
    {:noreply, apply_cycle(state)}
  end

  @impl true
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

  defp apply_cycle(state) do
    result = run_cycle()

    Logger.info(
      "[CircuitBreaker] Cycle #{state.poll_count + 1}: evaluated=#{result.evaluated} triggered=#{result.triggered}"
    )

    %{state | last_run: DateTime.utc_now(), poll_count: state.poll_count + 1}
  end

  defp list_enabled_strategies do
    from(s in LiveStrategy,
      where: s.enabled == true,
      select: %{id: s.id, strategy_type: s.strategy_type}
    )
    |> Repo.all()
  end

  defp open_suspension_ids([]), do: MapSet.new()

  defp open_suspension_ids(strategies) do
    ids = Enum.map(strategies, & &1.id)

    from(s in Suspension,
      where: s.live_strategy_id in ^ids and is_nil(s.cleared_at),
      select: s.live_strategy_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp maybe_suspend(strategy, stats) do
    thresholds =
      Map.get(@thresholds, strategy.strategy_type, %{
        consecutive_losses: nil,
        rolling_drawdown_pct: nil
      })

    cond do
      tripped_by_consecutive_losses?(strategy.id, thresholds, stats.consecutive) ->
        create_suspension(strategy.id, "consecutive_losses", consecutive_detail(thresholds))

      tripped_by_rolling_drawdown?(strategy.id, thresholds, stats.rolling) ->
        create_suspension(
          strategy.id,
          "rolling_drawdown",
          rolling_detail(Map.get(stats.rolling, strategy.id))
        )

      true ->
        :ok
    end
  end

  defp tripped_by_consecutive_losses?(
         _strategy_id,
         %{consecutive_losses: nil},
         _consecutive_stats
       ),
       do: false

  defp tripped_by_consecutive_losses?(
         strategy_id,
         %{consecutive_losses: limit},
         consecutive_stats
       ) do
    losses = Map.get(consecutive_stats, strategy_id, [])

    length(losses) == limit and Enum.all?(losses, &(&1 < 0.0))
  end

  defp tripped_by_rolling_drawdown?(_strategy_id, %{rolling_drawdown_pct: nil}, _rolling_stats),
    do: false

  defp tripped_by_rolling_drawdown?(
         strategy_id,
         %{rolling_drawdown_pct: threshold},
         rolling_stats
       ) do
    stats = Map.get(rolling_stats, strategy_id, %{count: 0, sum_pnl: 0.0})

    stats.count >= @rolling_min_sample and stats.sum_pnl < threshold
  end

  defp precompute_stats([]), do: %{consecutive: %{}, rolling: %{}}

  defp precompute_stats(strategies) do
    strategy_ids = Enum.map(strategies, & &1.id)

    max_consecutive_limit =
      strategies
      |> Enum.map(fn strategy ->
        Map.get(@thresholds, strategy.strategy_type, %{consecutive_losses: nil})
        |> Map.get(:consecutive_losses, 0)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    %{
      consecutive: fetch_recent_pnl_by_strategy(strategy_ids, max_consecutive_limit),
      rolling: fetch_rolling_stats_by_strategy(strategy_ids)
    }
  end

  defp fetch_recent_pnl_by_strategy(_strategy_ids, max_limit) when max_limit <= 0, do: %{}

  defp fetch_recent_pnl_by_strategy(strategy_ids, max_limit) do
    ranked_query =
      from(t in LiveTrade,
        where:
          t.live_strategy_id in ^strategy_ids and t.status == "closed" and
            not is_nil(t.pnl_percent),
        windows: [per_strategy: [partition_by: t.live_strategy_id, order_by: [desc: t.exit_time]]],
        select: %{
          live_strategy_id: t.live_strategy_id,
          pnl_percent: t.pnl_percent,
          rn: over(row_number(), :per_strategy)
        }
      )

    from(r in subquery(ranked_query),
      where: r.rn <= ^max_limit,
      order_by: [asc: r.live_strategy_id, asc: r.rn],
      select: {r.live_strategy_id, r.pnl_percent}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {strategy_id, pnl_percent}, acc ->
      Map.update(acc, strategy_id, [pnl_percent], &(&1 ++ [pnl_percent]))
    end)
  end

  defp fetch_rolling_stats_by_strategy(strategy_ids) do
    window_start = DateTime.add(DateTime.utc_now(), -@rolling_window_days * 86_400, :second)

    from(t in LiveTrade,
      where:
        t.live_strategy_id in ^strategy_ids and t.status == "closed" and
          not is_nil(t.pnl_percent) and t.exit_time >= ^window_start,
      group_by: t.live_strategy_id,
      select: {t.live_strategy_id, count(t.id), coalesce(sum(t.pnl_percent), 0.0)}
    )
    |> Repo.all()
    |> Map.new(fn {strategy_id, count, sum_pnl} ->
      {strategy_id, %{count: count, sum_pnl: sum_pnl}}
    end)
  end

  defp create_suspension(strategy_id, trigger_kind, trigger_detail) do
    attrs = %{
      live_strategy_id: strategy_id,
      triggered_at: DateTime.utc_now(),
      trigger_kind: trigger_kind,
      trigger_detail: trigger_detail
    }

    %Suspension{}
    |> Suspension.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :inserted

      {:error, reason} ->
        Logger.error(
          "[CircuitBreaker] Failed to persist suspension for #{strategy_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp consecutive_detail(%{consecutive_losses: limit}), do: "#{limit} losing trades in a row"

  defp rolling_detail(nil), do: "0.0% over #{@rolling_window_days}d across 0 trades"

  defp rolling_detail(%{count: count, sum_pnl: sum_pnl}) do
    "#{Float.round(sum_pnl, 2)}% over #{@rolling_window_days}d across #{count} trades"
  end
end
