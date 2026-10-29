defmodule Opus.Trading.CircuitBreaker do
  @moduledoc """
  Per-strategy circuit breaker: suspends a live strategy whose recent trades
  go badly, until a person resets it (`Opus.Trading.Strategies.reset_suspension/1`).
  An open suspension makes `Opus.Trading.RulesEngine` hold the strategy back.

  The same limits for every strategy:

  - `@consecutive_losses` losing trades in a row, or
  - its trades' returns summing below `@rolling_drawdown` over the last
    `@rolling_window_days` days, once it has at least `@rolling_min_sample`.

  Only trades closed since the strategy's last reset count, so a reset
  gives it a fresh start instead of tripping again on the same losses.
  Strategies marked `circuit_breaker_exempt` are left alone.

  Trade returns (`live_trades.pnl_percent`) are fractions: -0.08 is -8%.
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
  @consecutive_losses 5
  @rolling_drawdown -0.08
  @rolling_window_days 30
  @rolling_min_sample 5

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

    triggered =
      candidates
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
      where: s.enabled == true and s.circuit_breaker_exempt == false,
      select: %{id: s.id}
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
    trades = trades_since_reset(strategy.id)

    cond do
      losing_streak?(trades) ->
        create_suspension(
          strategy.id,
          "consecutive_losses",
          "#{@consecutive_losses} losing trades in a row"
        )

      rolling = rolling_drawdown(trades) ->
        create_suspension(strategy.id, "rolling_drawdown", rolling_detail(rolling))

      true ->
        :ok
    end
  end

  defp losing_streak?(trades) do
    latest = Enum.take(trades, @consecutive_losses)
    length(latest) == @consecutive_losses and Enum.all?(latest, &(&1.pnl < 0))
  end

  # The window's trades when they sum below the limit, else nil.
  defp rolling_drawdown(trades) do
    window_start = DateTime.add(DateTime.utc_now(), -@rolling_window_days, :day)
    window = Enum.filter(trades, &(DateTime.compare(&1.exit_time, window_start) != :lt))
    sum = Enum.sum_by(window, & &1.pnl)

    if length(window) >= @rolling_min_sample and sum < @rolling_drawdown,
      do: %{count: length(window), sum: sum}
  end

  # Closed trades since the strategy's last reset, newest first. Only the
  # last `@rolling_window_days` matter, plus enough for a losing streak.
  defp trades_since_reset(strategy_id) do
    since =
      from(s in Suspension,
        where: s.live_strategy_id == ^strategy_id and not is_nil(s.cleared_at),
        select: max(s.cleared_at)
      )
      |> Repo.one()

    from(t in LiveTrade,
      where:
        t.live_strategy_id == ^strategy_id and t.status == "closed" and
          not is_nil(t.pnl_percent) and not is_nil(t.exit_time),
      order_by: [desc: t.exit_time],
      select: %{pnl: t.pnl_percent, exit_time: t.exit_time}
    )
    |> after_reset(since)
    |> Repo.all()
  end

  defp after_reset(query, nil), do: query
  defp after_reset(query, since), do: where(query, [t], t.exit_time > ^since)

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

  defp rolling_detail(%{count: count, sum: sum}) do
    "#{Float.round(sum * 100, 1)}% over #{@rolling_window_days}d across #{count} trades"
  end
end
