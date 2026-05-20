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

    triggered =
      strategies
      |> Enum.reject(&MapSet.member?(open_ids, &1.id))
      |> Enum.reduce(0, fn strategy, acc ->
        case maybe_suspend(strategy) do
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

    Process.send_after(self(), :poll, @initial_delay)
    {:ok, %{last_run: nil, poll_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = apply_cycle(state)
    Process.send_after(self(), :poll, @poll_interval)
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
  rescue
    error ->
      Logger.error("[CircuitBreaker] cycle failed: #{Exception.message(error)}")
      state
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

  defp maybe_suspend(strategy) do
    thresholds =
      Map.get(@thresholds, strategy.strategy_type, %{
        consecutive_losses: nil,
        rolling_drawdown_pct: nil
      })

    cond do
      tripped_by_consecutive_losses?(strategy.id, thresholds) ->
        create_suspension(strategy.id, "consecutive_losses", consecutive_detail(thresholds))

      tripped_by_rolling_drawdown?(strategy.id, thresholds) ->
        create_suspension(strategy.id, "rolling_drawdown", rolling_detail(strategy.id))

      true ->
        :ok
    end
  end

  defp tripped_by_consecutive_losses?(_strategy_id, %{consecutive_losses: nil}), do: false

  defp tripped_by_consecutive_losses?(strategy_id, %{consecutive_losses: limit}) do
    losses =
      from(t in LiveTrade,
        where:
          t.live_strategy_id == ^strategy_id and t.status == "closed" and
            not is_nil(t.pnl_percent),
        order_by: [desc: t.exit_time],
        limit: ^limit,
        select: t.pnl_percent
      )
      |> Repo.all()

    length(losses) == limit and Enum.all?(losses, &(&1 < 0.0))
  end

  defp tripped_by_rolling_drawdown?(_strategy_id, %{rolling_drawdown_pct: nil}), do: false

  defp tripped_by_rolling_drawdown?(strategy_id, %{rolling_drawdown_pct: threshold}) do
    window_start = DateTime.add(DateTime.utc_now(), -@rolling_window_days * 86_400, :second)

    stats =
      from(t in LiveTrade,
        where:
          t.live_strategy_id == ^strategy_id and t.status == "closed" and
            not is_nil(t.pnl_percent) and t.exit_time >= ^window_start,
        select: %{count: count(t.id), sum_pnl: coalesce(sum(t.pnl_percent), 0.0)}
      )
      |> Repo.one()

    stats.count >= @rolling_min_sample and stats.sum_pnl < threshold
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

  defp rolling_detail(strategy_id) do
    window_start = DateTime.add(DateTime.utc_now(), -@rolling_window_days * 86_400, :second)

    stats =
      from(t in LiveTrade,
        where:
          t.live_strategy_id == ^strategy_id and t.status == "closed" and
            not is_nil(t.pnl_percent) and t.exit_time >= ^window_start,
        select: %{count: count(t.id), sum_pnl: coalesce(sum(t.pnl_percent), 0.0)}
      )
      |> Repo.one()

    "#{Float.round(stats.sum_pnl, 2)}% over #{@rolling_window_days}d across #{stats.count} trades"
  end
end
