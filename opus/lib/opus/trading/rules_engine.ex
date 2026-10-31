defmodule Opus.Trading.RulesEngine do
  @moduledoc """
  The account-level safety layer: decides, for every strategy in the
  universe, whether it may open new trades, and pushes the result to Rust.

  Each decision is persisted to the `rules` table and the full map is pushed
  via `Opus.Auro.Client.push_rules/1`. Rust holds it in `Arc<RwLock<Rules>>`
  and consults it on every entry signal; it only enforces the boolean.

  A strategy decides for itself whether conditions suit it (trend strength,
  calm or wild markets are blocks inside the strategy, tested by the
  pipeline). This layer never switches a strategy by regime. It holds a
  strategy back only for account safety, each cleared only by a person:

  - an account drawdown pause (`Opus.Trading.AccountPause`): every strategy;
  - an open circuit-breaker suspension (`Opus.Trading.CircuitBreaker`): that one.

  Each push also carries the account risk budget and per-group cap
  (`Opus.Trading.AccountLimits`), each strategy's risk per trade and each
  instrument's group; the engine checks those when a trade opens, since
  two strategies can fire in the same minute.

  Polls every minute, and recomputes at once when a suspension opens or
  clears. The engine refuses entries after a restart until its first push,
  so pushes come often; each is cheap.
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Support.Polling

  alias Opus.Trading.{
    AccountLimits,
    AccountPause,
    LiveStrategy,
    Rule,
    Suspension
  }

  import Ecto.Query

  @poll_interval :timer.minutes(1)
  @initial_delay :timer.seconds(30)

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate recompute (after a safety setting or suspension changes)."
  @spec recompute() :: :ok
  def recompute do
    GenServer.cast(__MODULE__, :recompute)
  end

  @doc "Computes decisions once, persists rules, and pushes to Rust."
  @spec compute_and_push() :: {:ok, list(map())} | {:error, term()}
  def compute_and_push do
    strategies = list_live_strategies()
    open_suspensions = open_suspensions_by_strategy(strategies)
    pause = AccountPause.check()
    decisions = Enum.map(strategies, &decide(&1, open_suspensions, pause))

    case persist_and_push(decisions, limits(strategies)) do
      :ok -> {:ok, decisions}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec last_run() :: DateTime.t() | nil
  def last_run, do: GenServer.call(__MODULE__, :last_run)

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    Logger.info("[RulesEngine] Started (#{div(@poll_interval, 60_000)}min poll interval)")

    Polling.schedule(self(), @initial_delay)
    {:ok, %{last_run: nil, poll_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = run_cycle(state)
    Polling.schedule(self(), @poll_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:recompute, state) do
    new_state = run_cycle(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

  # -- Core logic --

  # A failed cycle leaves the state unchanged; the next tick retries.
  defp run_cycle(state) do
    case compute_and_push() do
      {:ok, decisions} ->
        Logger.info(
          "[RulesEngine] cycle #{state.poll_count + 1}: #{summarize(decisions)} across #{length(decisions)} strategies"
        )

        %{state | last_run: DateTime.utc_now(), poll_count: state.poll_count + 1}

      {:error, reason} ->
        Logger.error("[RulesEngine] cycle failed: #{inspect(reason)}")
        state
    end
  end

  # Read all rows from `live_strategies`. Returns a list of maps with
  # the fields we need: `id`, `strategy_type`, `instrument`, `granularity`.
  defp list_live_strategies do
    from(s in LiveStrategy,
      select: %{
        id: s.id,
        strategy_type: s.strategy_type,
        instrument: s.instrument,
        granularity: s.granularity,
        sizing: s.sizing
      }
    )
    |> Repo.all()
  end

  # One strategy's decision: held back by an account pause or its own open
  # suspension.
  defp decide(strategy, open_suspensions, pause) do
    {enabled, reason} = safety(pause, Map.get(open_suspensions, strategy.id))

    %{
      live_strategy_id: strategy.id,
      enabled: enabled,
      reason: reason,
      risk_pct: AccountLimits.risk_pct(strategy.sizing),
      computed_at: DateTime.utc_now()
    }
  end

  defp safety(%AccountPause{} = p, _suspension) do
    down = Float.round(AccountPause.drawdown(p.peak_nav, p.nav) * 100, 1)
    {false, "account_pause: NAV fell #{down}% from its peak of #{round(p.peak_nav)}"}
  end

  defp safety(nil, %{trigger_detail: detail}), do: {false, "circuit_breaker: #{detail}"}
  defp safety(nil, nil), do: {true, "clear: no safety rule is holding it"}

  # The limits the engine checks when a trade opens (`AccountLimits`), with
  # each instrument's group. Nil before the limits exist: nothing is checked.
  defp limits(strategies) do
    case AccountLimits.get() do
      nil ->
        Logger.warning(
          "[RulesEngine] No account limits stored (trading_config account_limits); " <>
            "pushing without a risk budget or group caps"
        )

        nil

      %{risk_budget_pct: budget, max_open_per_group: per_group} ->
        %{
          risk_budget: budget / 100,
          max_open_per_group: per_group,
          groups: AccountLimits.groups(Enum.map(strategies, & &1.instrument))
        }
    end
  end

  defp open_suspensions_by_strategy([]), do: %{}

  defp open_suspensions_by_strategy(strategies) do
    strategy_ids = Enum.map(strategies, & &1.id)

    from(s in Suspension,
      where: s.live_strategy_id in ^strategy_ids and is_nil(s.cleared_at),
      order_by: [desc: s.triggered_at],
      select: %{live_strategy_id: s.live_strategy_id, trigger_detail: s.trigger_detail}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn suspension, acc ->
      Map.put_new(acc, suspension.live_strategy_id, suspension)
    end)
  end

  # Persist all decisions to the rules table, then push the full map to Rust.
  # Returns `:ok` or `{:error, reason}`. If persistence succeeds but push fails,
  # return error — the next tick will re-push with whatever's in the DB.
  defp persist_and_push(decisions, limits) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(decisions, fn d ->
        %{
          live_strategy_id: d.live_strategy_id,
          enabled: d.enabled,
          reason: d.reason,
          computed_at: d.computed_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(
      Rule,
      rows,
      on_conflict: {:replace, [:enabled, :reason, :computed_at, :updated_at]},
      conflict_target: :live_strategy_id
    )

    rules_map =
      Enum.into(decisions, %{}, fn d ->
        {Ecto.UUID.cast!(d.live_strategy_id),
         %{enabled: d.enabled, reason: d.reason, risk_pct: d.risk_pct}}
      end)

    payload = %{
      rules: rules_map,
      limits: limits,
      computed_at: DateTime.utc_now()
    }

    case Auro.push_rules(payload) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp summarize(decisions) do
    decisions
    |> Enum.frequencies_by(& &1.enabled)
    |> Enum.map(fn
      {true, count} -> "enabled=#{count}"
      {false, count} -> "disabled=#{count}"
    end)
    |> Enum.join(", ")
  end
end
