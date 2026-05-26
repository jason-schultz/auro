defmodule Opus.Trading.StrategyCurator do
  @moduledoc """
  Auto-curates `live_strategies.enabled` for strategies in `curator_mode = "auto"`.

  Promotion requires 3 consecutive favorable rules decisions.
  Demotion requires 6 consecutive unfavorable decisions and
  no open position for the strategy.
  """

  use GenServer
  require Logger

  alias Opus.Repo
  alias Opus.Support.Polling
  alias Opus.Trading.{CuratorDecision, LiveStrategy, Rule, Suspension}

  import Ecto.Query

  @poll_interval :timer.minutes(5)
  @initial_delay :timer.seconds(45)

  @promote_consecutive 3
  @demote_consecutive 6

  @type history_entry :: %{
          rules_enabled: boolean() | nil,
          reason: String.t(),
          composite_regime: String.t() | nil,
          frames: list(map()),
          computed_at: DateTime.t() | nil
        }

  @type history_state :: %{optional(Ecto.UUID.t()) => list(history_entry())}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate curator cycle in the running GenServer."
  def recompute do
    GenServer.call(__MODULE__, :run_once)
  end

  @doc "Runs one curator cycle using the provided in-memory history map."
  @spec run_cycle(history_state()) :: %{
          history: history_state(),
          promoted: non_neg_integer(),
          demoted: non_neg_integer(),
          no_op: non_neg_integer(),
          skipped_by_flag: non_neg_integer()
        }
  def run_cycle(history \\ %{}) do
    strategies = list_auto_strategies()

    if curator_enabled?() do
      do_run_enabled_cycle(strategies, history)
    else
      Logger.info("[Curator] disabled by trading_config, skipping cycle")

      %{
        history: history,
        promoted: 0,
        demoted: 0,
        no_op: length(strategies),
        skipped_by_flag: length(strategies)
      }
    end
  end

  @impl true
  def init(_opts) do
    Logger.info("[Curator] Started (#{div(@poll_interval, 60_000)}min poll interval)")
    Polling.schedule(self(), @initial_delay)
    {:ok, %{history: %{}, last_run: nil, poll_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    result = run_cycle(state.history)

    Logger.info(
      "[Curator] cycle #{state.poll_count + 1}: promoted=#{result.promoted}, demoted=#{result.demoted}, no-op=#{result.no_op}"
    )

    Polling.schedule(self(), @poll_interval)

    {:noreply,
     %{
       state
       | history: result.history,
         last_run: DateTime.utc_now(),
         poll_count: state.poll_count + 1
     }}
  end

  @impl true
  def handle_call(:run_once, _from, state) do
    result = run_cycle(state.history)

    {:reply, result,
     %{
       state
       | history: result.history,
         last_run: DateTime.utc_now(),
         poll_count: state.poll_count + 1
     }}
  end

  defp do_run_enabled_cycle(strategies, history) do
    strategy_ids = Enum.map(strategies, & &1.id)
    rules_by_strategy = rules_by_strategy(strategy_ids)
    open_suspensions = open_suspensions_by_strategy(strategy_ids)

    history_with_current = append_cycle_snapshots(history, strategies, rules_by_strategy)

    {promoted, demoted, no_op} =
      Enum.reduce(strategies, {0, 0, 0}, fn strategy, {promoted_acc, demoted_acc, no_op_acc} ->
        case decide_action(strategy, history_with_current, open_suspensions) do
          {:promote, reason, rules_window} ->
            case update_strategy_enabled(strategy.id, true) do
              :ok ->
                insert_decision(strategy.id, "promoted", reason, rules_window)
                {promoted_acc + 1, demoted_acc, no_op_acc}

              :noop ->
                {promoted_acc, demoted_acc, no_op_acc + 1}
            end

          {:demote, reason, rules_window} ->
            case update_strategy_enabled(strategy.id, false) do
              :ok ->
                insert_decision(strategy.id, "demoted", reason, rules_window)
                {promoted_acc, demoted_acc + 1, no_op_acc}

              :noop ->
                {promoted_acc, demoted_acc, no_op_acc + 1}
            end

          :no_op ->
            {promoted_acc, demoted_acc, no_op_acc + 1}
        end
      end)

    %{
      history: history_with_current,
      promoted: promoted,
      demoted: demoted,
      no_op: no_op,
      skipped_by_flag: 0
    }
  end

  defp list_auto_strategies do
    from(s in LiveStrategy,
      where: s.curator_mode == "auto",
      select: %{id: s.id, enabled: s.enabled}
    )
    |> Repo.all()
  end

  defp rules_by_strategy([]), do: %{}

  defp rules_by_strategy(strategy_ids) do
    from(r in Rule,
      where: r.live_strategy_id in ^strategy_ids,
      select: %{
        live_strategy_id: r.live_strategy_id,
        enabled: r.enabled,
        reason: r.reason,
        computed_at: r.computed_at,
        regime_inputs: r.regime_inputs
      }
    )
    |> Repo.all()
    |> Map.new(fn row -> {row.live_strategy_id, row} end)
  end

  defp append_cycle_snapshots(history, strategies, rules_by_strategy) do
    Enum.reduce(strategies, history, fn strategy, acc ->
      latest_rule = Map.get(rules_by_strategy, strategy.id)
      {composite_regime, frames} = parse_regime_inputs(latest_rule && latest_rule.regime_inputs)

      snapshot = %{
        rules_enabled: latest_rule && latest_rule.enabled,
        reason: (latest_rule && latest_rule.reason) || "no decision yet",
        composite_regime: composite_regime,
        frames: frames,
        computed_at: latest_rule && latest_rule.computed_at
      }

      acc
      |> Map.get(strategy.id, [])
      |> then(fn previous -> [snapshot | previous] end)
      |> Enum.take(@demote_consecutive)
      |> then(&Map.put(acc, strategy.id, &1))
    end)
  end

  defp open_suspensions_by_strategy([]), do: MapSet.new()

  defp open_suspensions_by_strategy(strategy_ids) do
    from(s in Suspension,
      where: s.live_strategy_id in ^strategy_ids and is_nil(s.cleared_at),
      select: s.live_strategy_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp decide_action(strategy, history, open_suspensions) do
    window = Map.get(history, strategy.id, [])

    cond do
      strategy.enabled == false and MapSet.member?(open_suspensions, strategy.id) ->
        :no_op

      strategy.enabled == false and consecutive?(window, @promote_consecutive, true) ->
        {:promote, "#{@promote_consecutive} cycles favorable",
         build_rules_window(window, @promote_consecutive)}

      strategy.enabled == true and has_open_position?(strategy.id) ->
        :no_op

      strategy.enabled == true and consecutive?(window, @demote_consecutive, false) ->
        {:demote, "#{@demote_consecutive} cycles unfavorable",
         build_rules_window(window, @demote_consecutive)}

      true ->
        :no_op
    end
  end

  defp consecutive?(window, required, target_enabled) when is_list(window) do
    window
    |> Enum.take(required)
    |> case do
      slice when length(slice) < required ->
        false

      slice ->
        Enum.all?(slice, &(&1.rules_enabled == target_enabled))
    end
  end

  defp build_rules_window(window, required) do
    %{
      required_consecutive: required,
      samples: Enum.take(window, required)
    }
  end

  defp has_open_position?(strategy_id) do
    strategy_id_db = Ecto.UUID.dump!(strategy_id)

    from(t in "live_trades",
      where: t.live_strategy_id == ^strategy_id_db and t.status == "open",
      select: count()
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp update_strategy_enabled(strategy_id, enabled) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated_count, _} =
      from(s in LiveStrategy,
        where: s.id == ^strategy_id and s.curator_mode == "auto"
      )
      |> Repo.update_all(set: [enabled: enabled, updated_at: now])

    if updated_count > 0, do: :ok, else: :noop
  end

  defp insert_decision(strategy_id, action, reason, rules_window) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(CuratorDecision, [
      %{
        live_strategy_id: strategy_id,
        action: action,
        reason: reason,
        rules_window: rules_window,
        decided_at: now,
        created_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  defp parse_regime_inputs(nil), do: {nil, []}

  defp parse_regime_inputs(regime_inputs) do
    composite = regime_inputs |> value_for([:composite, "composite"]) |> normalize_regime()

    frames =
      regime_inputs
      |> value_for([:frames, "frames"])
      |> case do
        list when is_list(list) ->
          Enum.map(list, fn frame ->
            %{
              frame: value_for(frame, [:frame, "frame"]),
              regime: frame |> value_for([:regime, "regime"]) |> normalize_regime(),
              adx: value_for(frame, [:adx, "adx"])
            }
          end)

        _ ->
          []
      end

    {composite, frames}
  end

  defp value_for(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp value_for(_value, _keys), do: nil

  defp normalize_regime(nil), do: nil
  defp normalize_regime(regime) when is_atom(regime), do: Atom.to_string(regime)
  defp normalize_regime(regime), do: regime

  defp curator_enabled? do
    case Repo.query("SELECT to_regclass('public.trading_config')") do
      {:ok, %{rows: [[nil]]}} ->
        false

      {:ok, _} ->
        from(c in "trading_config",
          where: c.key == "curator_enabled",
          select: c.value
        )
        |> Repo.one()
        |> to_bool_value(false)

      {:error, _reason} ->
        false
    end
  end

  defp to_bool_value(nil, default), do: default
  defp to_bool_value(value, _default) when is_boolean(value), do: value

  defp to_bool_value(value, default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp to_bool_value(%{"value" => nested}, default), do: to_bool_value(nested, default)
  defp to_bool_value(%{value: nested}, default), do: to_bool_value(nested, default)
  defp to_bool_value(_value, default), do: default
end
