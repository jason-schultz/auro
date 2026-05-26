defmodule Opus.Trading.StrategyCuratorTest do
  use Opus.DataCase, async: false

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.{CuratorDecision, LiveStrategy, Rule, StrategyCurator}

  setup do
    Repo.delete_all(CuratorDecision)
    Repo.delete_all(Rule)
    from(t in "live_trades") |> Repo.delete_all()
    Repo.delete_all(LiveStrategy)

    Repo.query!(
      "INSERT INTO trading_config (key, value, updated_at) VALUES ('curator_enabled', 'false'::jsonb, NOW()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()"
    )

    :ok
  end

  test "promotes auto strategy after sustained favorable rules" do
    strategy_id = insert_strategy(enabled: false, curator_mode: "auto")
    set_curator_enabled(true)

    history =
      Enum.reduce(1..3, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, true, "favorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert map_size(history) == 1
    assert strategy_enabled?(strategy_id)

    decision = latest_decision(strategy_id)
    assert decision.action == "promoted"
  end

  test "demotes auto strategy after sustained unfavorable rules with no open position" do
    strategy_id = insert_strategy(enabled: true, curator_mode: "auto")
    set_curator_enabled(true)

    history =
      Enum.reduce(1..6, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, false, "unfavorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert map_size(history) == 1
    refute strategy_enabled?(strategy_id)

    decision = latest_decision(strategy_id)
    assert decision.action == "demoted"
  end

  test "demote is blocked when strategy has open position" do
    strategy_id = insert_strategy(enabled: true, curator_mode: "auto")
    set_curator_enabled(true)
    insert_open_trade(strategy_id)

    history =
      Enum.reduce(1..6, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, false, "unfavorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert map_size(history) == 1
    assert strategy_enabled?(strategy_id)
    assert latest_decision(strategy_id) == nil
  end

  test "pinned_on strategy is skipped" do
    strategy_id = insert_strategy(enabled: true, curator_mode: "pinned_on")
    set_curator_enabled(true)

    history =
      Enum.reduce(1..6, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, false, "unfavorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert history == %{}
    assert strategy_enabled?(strategy_id)
    assert latest_decision(strategy_id) == nil
  end

  test "pinned_off strategy is skipped" do
    strategy_id = insert_strategy(enabled: false, curator_mode: "pinned_off")
    set_curator_enabled(true)

    history =
      Enum.reduce(1..3, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, true, "favorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert history == %{}
    refute strategy_enabled?(strategy_id)
    assert latest_decision(strategy_id) == nil
  end

  test "feature flag off performs no actions" do
    strategy_id = insert_strategy(enabled: false, curator_mode: "auto")
    set_curator_enabled(false)

    history =
      Enum.reduce(1..3, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, true, "favorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert history == %{}
    refute strategy_enabled?(strategy_id)
    assert latest_decision(strategy_id) == nil
  end

  test "insufficient history does not promote" do
    strategy_id = insert_strategy(enabled: false, curator_mode: "auto")
    set_curator_enabled(true)

    history =
      Enum.reduce(1..2, %{}, fn _cycle, history_acc ->
        upsert_rule(strategy_id, true, "favorable")
        StrategyCurator.run_cycle(history_acc).history
      end)

    assert map_size(history) == 1
    refute strategy_enabled?(strategy_id)
    assert latest_decision(strategy_id) == nil
  end

  defp insert_strategy(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    id = Ecto.UUID.generate()

    Repo.insert_all(LiveStrategy, [
      %{
        id: id,
        strategy_type: "trend_following",
        instrument: "EUR_USD",
        granularity: "H1",
        parameters: %{},
        enabled: Keyword.fetch!(opts, :enabled),
        curator_mode: Keyword.fetch!(opts, :curator_mode),
        max_position_size: "1000",
        created_at: now,
        updated_at: now
      }
    ])

    id
  end

  defp upsert_rule(strategy_id, enabled, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      Rule,
      [
        %{
          live_strategy_id: strategy_id,
          enabled: enabled,
          reason: reason,
          regime_inputs: %{
            "composite" => if(enabled, do: "trending", else: "choppy"),
            "frames" => [
              %{
                "frame" => "H4",
                "regime" => if(enabled, do: "trending", else: "choppy"),
                "adx" => if(enabled, do: 32.5, else: 12.4)
              }
            ]
          },
          computed_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:enabled, :reason, :regime_inputs, :computed_at, :updated_at]},
      conflict_target: :live_strategy_id
    )
  end

  defp insert_open_trade(strategy_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    strategy_id_db = Ecto.UUID.dump!(strategy_id)
    trade_id_db = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Repo.insert_all("live_trades", [
      %{
        id: trade_id_db,
        live_strategy_id: strategy_id_db,
        oanda_trade_id: "T-#{Ecto.UUID.generate()}",
        instrument: "EUR_USD",
        direction: "Long",
        units: "1000",
        status: "open",
        entry_time: now,
        created_at: now,
        updated_at: now
      }
    ])
  end

  defp set_curator_enabled(enabled) do
    value = if(enabled, do: "true", else: "false")

    Repo.query!(
      "INSERT INTO trading_config (key, value, updated_at) VALUES ('curator_enabled', $1::jsonb, NOW()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
      [value]
    )
  end

  defp strategy_enabled?(strategy_id) do
    from(s in LiveStrategy, where: s.id == ^strategy_id, select: s.enabled)
    |> Repo.one()
  end

  defp latest_decision(strategy_id) do
    from(d in CuratorDecision,
      where: d.live_strategy_id == ^strategy_id,
      order_by: [desc: d.decided_at],
      limit: 1
    )
    |> Repo.one()
  end
end
