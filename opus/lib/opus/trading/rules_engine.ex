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

  Multi-timeframe regime classification (H4 anchor + H1 confirmation, M15
  vetoes):

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
      | trend_following  | enabled   | disabled  | enabled   | disabled  |
      | mean_reversion   | disabled  | enabled   | enabled   | disabled  |

  `:uncertain` defaults to enabled. Most ADX readings fall in the 20-30
  uncertain band; disabling there starves the strategies of trades without
  fixing the root cause of poor outcomes (which is usually exit logic, not
  entry filtering). When dynamic position sizing lands, `:uncertain` should
  scale to reduced size rather than full size.

  `:unknown` fails closed — missing regime data is treated as no signal.
  Rust's `Rules::decision` fails open on an empty rules map as the bootstrap
  safety net, but once Opus has computed and pushed any rules, the policy
  defined here is authoritative.
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, RegimeDetector, Rule, Suspension}

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
    strategies = list_enabled_strategies()
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

  @impl true
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

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

  # Read all enabled rows from `live_strategies`. Returns a list of maps with
  # the fields we need: `id`, `strategy_type`, `instrument`, `granularity`.
  defp list_enabled_strategies do
    from(s in LiveStrategy,
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

  # Derive a single decision from a strategy and the current regime map.
  # Returns a map: `%{live_strategy_id, enabled, reason, computed_at}`.
  defp decide(strategy, regimes, open_suspensions) do
    case Map.get(open_suspensions, strategy.id) do
      %{trigger_detail: trigger_detail} ->
        %{
          live_strategy_id: strategy.id,
          enabled: false,
          reason: "circuit_breaker: #{trigger_detail}",
          computed_at: DateTime.utc_now()
        }

      nil ->
        decide_from_regime(strategy, regimes)
    end
  end

  defp decide_from_regime(strategy, regimes) do
    d = Map.get(regimes, {strategy.instrument, "D"}, %{regime: :unknown})
    h4 = Map.get(regimes, {strategy.instrument, "H4"}, %{regime: :unknown})
    h1 = Map.get(regimes, {strategy.instrument, "H1"}, %{regime: :unknown})
    m15 = Map.get(regimes, {strategy.instrument, "M15"}, %{regime: :unknown})

    regime = classify_mtf(h4, h1, m15)
    {enabled, reason} = policy(strategy.strategy_type, regime, d, h4, h1, m15)

    %{
      live_strategy_id: strategy.id,
      enabled: enabled,
      reason: reason,
      computed_at: DateTime.utc_now()
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

  # H4 anchors the trend; H1 must agree to lock in trending or choppy. M15 can
  # veto: if it contradicts H4 and H1, downgrade to :uncertain. If either
  # anchor is unknown, the whole composite is unknown (fail-closed).
  defp classify_mtf(h4, h1, m15) do
    h4_regime = h4[:regime] || :unknown
    h1_regime = h1[:regime] || :unknown
    m15_regime = m15[:regime] || :unknown

    case {h4_regime, h1_regime} do
      {:unknown, _} ->
        :unknown

      {_, :unknown} ->
        :unknown

      {:trending, :trending} ->
        if m15_regime == :choppy, do: :uncertain, else: :trending

      {:choppy, :choppy} ->
        if m15_regime == :trending, do: :uncertain, else: :choppy

      _ ->
        # H4 and H1 disagree — mixed signals, avoid both strategies
        :uncertain
    end
  end

  defp policy("trend_following", :trending, d, h4, h1, m15),
    do: {true, "trending TF enabled — #{adx_line(d, h4, h1, m15)}"}

  defp policy("trend_following", :choppy, d, h4, h1, m15),
    do: {false, "choppy TF disabled — #{adx_line(d, h4, h1, m15)}"}

  defp policy("trend_following", :uncertain, d, h4, h1, m15),
    do: {true, "uncertain TF enabled (fail-open) — #{adx_line(d, h4, h1, m15)}"}

  defp policy("mean_reversion", :choppy, d, h4, h1, m15),
    do: {true, "choppy MR enabled — #{adx_line(d, h4, h1, m15)}"}

  defp policy("mean_reversion", :trending, d, h4, h1, m15),
    do: {false, "trending MR disabled — #{adx_line(d, h4, h1, m15)}"}

  defp policy("mean_reversion", :uncertain, d, h4, h1, m15),
    do: {true, "uncertain MR enabled (fail-open) — #{adx_line(d, h4, h1, m15)}"}

  # fail-closed: unknown regime, unknown strategy_type, etc.
  defp policy(_strategy_type, regime, _d, _h4, _h1, _m15),
    do: {false, "no regime data (#{inspect(regime)}) — defaulting to disabled"}

  defp adx_line(d, h4, h1, m15) do
    "D:#{format_adx(d[:adx])} H4:#{format_adx(h4[:adx])} " <>
      "H1:#{format_adx(h1[:adx])} M15:#{format_adx(m15[:adx])}"
  end

  defp format_adx(nil), do: "n/a"
  defp format_adx(adx), do: :erlang.float_to_binary(adx, decimals: 1)

  # Persist all decisions to the rules table, then push the full map to Rust.
  # Returns `:ok` or `{:error, reason}`. If persistence succeeds but push fails,
  # return error — the next tick will re-push with whatever's in the DB.
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
