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

  Per-granularity regimes come from `Opus.Trading.RegimeDetector`, which
  classifies the ADX scalar at each timeframe: trending if ADX >= 30, choppy
  if ADX < 20, uncertain in between, unknown if the buffer is too short.

    Regime classification is strategy-granularity aware (dual-frame by default):

      | Entry granularity | Context frame | Execution frame |
      | ----------------- | ------------- | --------------- |
      | M1                | M5            | M1              |
      | M5                | M15           | M5              |
      | M15               | H1            | M15             |
      | H1                | H4            | H1              |
      | H4                | D             | H4              |

    Classification rule for dual-frame inputs:

      | Context | Execution | Composite |
      | ------- | --------- | --------- |
      | same trend state    | same      | that state |
      | mismatch            | mismatch  | uncertain  |
      | any unknown         | any       | unknown    |

    Legacy 3-frame majority (H4/H1/M15) remains available in
    `RegimeClassifier.classify_mtf/3` for back-compat tests and optional callers.

      | H4 regime  | H1 regime  | M15 regime    | composite |
      | ---------- | ---------- | ------------- | --------- |
      | trending   | trending   | not :choppy   | trending  |
      | trending   | trending   | :choppy       | uncertain |
      | choppy     | choppy     | not :trending | choppy    |
      | choppy     | choppy     | :trending     | uncertain |
      | H4 and H1 disagree                       | uncertain |
      | :unknown in H4 or H1                     | unknown   |

  H4 anchors the trend; H1 confirms; M15 is the ripple that can veto. D is
  polled by `RegimeDetector` for diagnostic visibility (its ADX shows up in
  rule reason strings) but does NOT gate decisions — D as a hard anchor for
  H1-timeframe strategies is too far away from the strategy's holding period
  and produces excessive false uncertain classifications. Future use of D
  belongs in position sizing or sector-context features, not entry gating.

  Strategy-type × composite regime → decision (the policy):

      | strategy_type    | trending  | choppy    | uncertain | unknown   |
      | ---------------- | --------- | --------- | --------- | --------- |
        | trend_following  | enabled   | disabled  | disabled  | disabled  |
        | mean_reversion   | disabled  | enabled   | disabled  | disabled  |

  `:unknown` fails closed — missing regime data is treated as no signal.
  Rust's `Rules::decision` fails open on an empty rules map as the bootstrap
  safety net, but once Opus has computed and pushed any rules, the policy
  defined here is authoritative.
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Support.Polling
  alias Opus.Trading.{LiveStrategy, RegimeClassifier, RegimeDetector, Rule, Suspension}

  import Ecto.Query

  @poll_interval :timer.minutes(5)
  @initial_delay :timer.seconds(30)

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate recompute (for testing or manual trigger from FE)."
  def recompute do
    GenServer.cast(__MODULE__, :recompute)
  end

  def recompute_now, do: recompute()

  @doc "Computes decisions once, persists rules, and pushes to Rust."
  @spec compute_and_push() :: {:ok, list(map())} | {:error, term()}
  def compute_and_push do
    strategies = list_live_strategies()
    regimes = RegimeDetector.get_all_regimes()
    open_suspensions = open_suspensions_by_strategy(strategies)
    decisions = Enum.map(strategies, &decide(&1, regimes, open_suspensions))

    case persist_and_push(decisions) do
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

  defp run_cycle(state) do
    # Skeleton of the cycle. Each step is a defp — fill in the bodies in order.
    #
    # 1. Read all live_strategies rows in the universe.
    # 2. Read current regime map from RegimeDetector.
    # 3. For each strategy, derive a decision (enabled?, reason).
    # 4. Persist each decision to the `rules` table (upsert).
    # 5. Push the full map to Rust via Auro.Client.push_rules/1.
    # 6. Log a one-line summary.
    #
    # If any step fails, log and return state unchanged so the next tick retries.

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
        granularity: s.granularity
      }
    )
    |> Repo.all()
  end

  # Derive a single decision from a strategy and the current regime map.
  # Returns a map: `%{live_strategy_id, enabled, reason, computed_at}`.
  defp decide(strategy, regimes, open_suspensions) do
    inputs = regime_inputs_for_strategy(strategy, regimes)
    composite = RegimeClassifier.classify_for_inputs(inputs)
    regime_inputs = to_structured_regime_inputs(composite, inputs)

    case Map.get(open_suspensions, strategy.id) do
      %{trigger_detail: trigger_detail} ->
        %{
          live_strategy_id: strategy.id,
          enabled: false,
          reason: "circuit_breaker: #{trigger_detail}",
          regime_inputs: regime_inputs,
          computed_at: DateTime.utc_now()
        }

      nil ->
        decide_from_regime(strategy, inputs, composite, regime_inputs)
    end
  end

  defp decide_from_regime(strategy, inputs, composite, regime_inputs) do
    {enabled, reason} =
      RegimeClassifier.policy_for_inputs(strategy.strategy_type, composite, inputs)

    %{
      live_strategy_id: strategy.id,
      enabled: enabled,
      reason: reason,
      regime_inputs: regime_inputs,
      computed_at: DateTime.utc_now()
    }
  end

  defp regime_inputs_for_strategy(strategy, regimes) do
    strategy.granularity
    |> Opus.Trading.Granularity.regime_frames_for_entry()
    |> Enum.map(fn frame ->
      {frame, Map.get(regimes, {strategy.instrument, frame}, %{regime: :unknown})}
    end)
  end

  defp to_structured_regime_inputs(composite, frame_inputs) do
    %{
      composite: composite,
      frames:
        Enum.map(frame_inputs, fn {frame, frame_data} ->
          %{
            frame: frame,
            regime: Map.get(frame_data, :regime),
            adx: Map.get(frame_data, :adx)
          }
        end)
    }
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
  defp persist_and_push(decisions) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(decisions, fn d ->
        %{
          live_strategy_id: d.live_strategy_id,
          enabled: d.enabled,
          reason: d.reason,
          regime_inputs: d.regime_inputs,
          computed_at: d.computed_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(
      Rule,
      rows,
      on_conflict: {:replace, [:enabled, :reason, :regime_inputs, :computed_at, :updated_at]},
      conflict_target: :live_strategy_id
    )

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
