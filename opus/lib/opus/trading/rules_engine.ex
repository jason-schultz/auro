defmodule Opus.Trading.RulesEngine do
  @moduledoc """
  Computes per-strategy enable/disable decisions from regime state and pushes
  them to Rust.

  Per Decision #23, this is the active side of the rules engine: persists each
  decision to the `rules` table AND pushes the full payload to Rust via
  `Opus.Auro.Client.push_rules/1`. Rust holds the result in `Arc<RwLock<Rules>>`
  and consults it on every entry signal.

  Per Decision #18, the *condition* (e.g. "ADX > 25") lives here. Rust never
  decides — it only enforces the boolean.

  Polls every 5 minutes by default. Same cadence as RegimeDetector since rules
  derive from regimes — running more often than the source of truth wastes work.

  Strategy-type → regime → decision mapping (the policy):

      | strategy_type    | trending  | choppy    | uncertain | unknown   |
      | ---------------- | --------- | --------- | --------- | --------- |
      | trend_following  | enabled   | disabled  | disabled  | enabled   |
      | mean_reversion   | disabled  | enabled   | disabled  | enabled   |

  "Unknown" defaults to enabled so a fresh start (before regime detector has
  any data) doesn't accidentally disable everything. Same fail-open posture as
  Rust's `Rules::decision`.
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Trading.{Rule, RegimeDetector}

  import Ecto.Query

  @poll_interval :timer.minutes(5)
  @initial_delay :timer.seconds(30)

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate recompute (for testing or manual trigger from FE)."
  def recompute_now do
    GenServer.cast(__MODULE__, :recompute)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    Logger.info("[RulesEngine] Started (#{div(@poll_interval, 60_000)}min poll interval)")

    Process.send_after(self(), :poll, @initial_delay)
    {:ok, %{last_run: nil, poll_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = run_cycle(state)
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:recompute, state) do
    new_state = run_cycle(state)
    {:noreply, new_state}
  end

  # -- Core logic --

  defp run_cycle(state) do
    # Skeleton of the cycle. Each step is a defp — fill in the bodies in order.
    #
    # 1. Read all enabled live_strategies (we only compute rules for active ones).
    # 2. Read current regime map from RegimeDetector.
    # 3. For each strategy, derive a decision (enabled?, reason).
    # 4. Persist each decision to the `rules` table (upsert).
    # 5. Push the full map to Rust via Auro.Client.push_rules/1.
    # 6. Log a one-line summary.
    #
    # If any step fails, log and return state unchanged so the next tick retries.

    strategies = list_enabled_strategies()
    regimes = RegimeDetector.get_all_regimes()
    decisions = Enum.map(strategies, &decide(&1, regimes))

    case persist_and_push(decisions) do
      :ok ->
        Logger.info(
          "[RulesEngine] cycle #{state.poll_count + 1}: #{summarize(decisions)} across #{length(decisions)} strategies"
        )

        %{state | last_run: DateTime.utc_now(), poll_count: state.poll_count + 1}

      {:error, reason} ->
        Logger.error("[RulesEngine] cycle failed: #{inspect(reason)}")
        state
    end
  end

  @doc """
  Read all enabled rows from `live_strategies`. Returns a list of maps with
  the fields we need: `id`, `strategy_type`, `instrument`, `granularity`.
  """
  defp list_enabled_strategies do
    from(s in "live_strategies",
      where: s.enabled == true,
      select: %{
        id: s.id,
        strategy_type: s.strategy_type,
        instrument: s.instrument,
        granularity: s.granularity
      }
    )
    |> Repo.all()
  end

  @doc """
  Derive a single decision from a strategy and the current regime map.

  Returns a map: `%{live_strategy_id, enabled, reason, computed_at}`.
  """
  defp decide(strategy, regimes) do
    # The regimes map is keyed by `{instrument, granularity}` per
    # RegimeDetector.get_all_regimes. Look up this strategy's pair to find
    # its regime data, then apply the strategy_type × regime policy table.
    regime_data =
      Map.get(regimes, {strategy.instrument, strategy.granularity}, %{regime: :unknown})

    regime = regime_data[:regime] || :unknown

    {enabled, reason} = policy(strategy.strategy_type, regime, regime_data)

    %{
      live_strategy_id: strategy.id,
      enabled: enabled,
      reason: reason,
      computed_at: DateTime.utc_now()
    }
  end

  defp policy("trend_following", :trending, data),
    do: {true, "trending regime, ADX #{format_adx(data[:adx])}"}

  defp policy("trend_following", :choppy, data),
    do: {false, "choppy regime, TF disabled (ADX #{format_adx(data[:adx])})"}

  defp policy("trend_following", :uncertain, data),
    do: {false, "uncertain regime, TF disabled (ADX #{format_adx(data[:adx])})"}

  defp policy("mean_reversion", :choppy, data),
    do: {true, "choppy regime, ADX #{format_adx(data[:adx])}"}

  defp policy("mean_reversion", :trending, data),
    do: {false, "trending regime, MR disabled (ADX #{format_adx(data[:adx])})"}

  # fail-open: unknown regime, unknown strategy_type, etc.
  defp policy(_strategy_type, _regime, _data),
    do: {true, "no policy match — defaulting to enabled"}

  defp format_adx(nil), do: "n/a"
  defp format_adx(adx), do: :erlang.float_to_binary(adx, decimals: 1)

  @doc """
  Persist all decisions to the rules table, then push the full map to Rust.

  Returns `:ok` or `{:error, reason}`. If persistence succeeds but push fails,
  return error — the next tick will re-push with whatever's in the DB.
  """
  defp persist_and_push(decisions) do
    Enum.each(decisions, fn d ->
      %Rule{}
      |> Rule.changeset(d)
      |> Repo.insert(
        on_conflict: {:replace, [:enabled, :reason, :computed_at, :updated_at]},
        conflict_target: :live_strategy_id
      )
    end)

    rules_map =
      Enum.into(decisions, %{}, fn d ->
        {Ecto.UUID.cast!(d.live_strategy_id), %{enabled: d.enabled, reason: d.reason}}
      end)

    payload = %{
      rules: rules_map,
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
