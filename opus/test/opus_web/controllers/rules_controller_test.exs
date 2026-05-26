defmodule OpusWeb.RulesControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, Rule}

  import Ecto.Query

  setup do
    Repo.delete_all(Rule)
    Repo.delete_all(LiveStrategy)

    case Repo.query("SELECT to_regclass('public.trading_config')") do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, _} ->
        from(c in "trading_config", where: c.key == "curator_enabled")
        |> Repo.delete_all()

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  test "returns empty payload when no live strategies exist", %{conn: conn} do
    conn = get(conn, "/api/rules/state")
    body = json_response(conn, 200)

    assert body["computed_at"] == nil
    assert body["summary"] == %{"trading" => 0, "live" => 0, "curator_enabled" => false}
    assert body["strategies"] == []
  end

  test "returns empty when all strategies are disabled", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(LiveStrategy, [
      %{
        id: Ecto.UUID.generate(),
        instrument: "EUR_USD",
        granularity: "M15",
        strategy_type: "trend",
        parameters: %{},
        enabled: false,
        curator_mode: "auto",
        max_position_size: "0.02",
        created_at: now,
        updated_at: now
      }
    ])

    conn = get(conn, "/api/rules/state")
    body = json_response(conn, 200)

    assert body["computed_at"] == nil
    assert body["summary"] == %{"trading" => 0, "live" => 0, "curator_enabled" => false}
    assert body["strategies"] == []
  end

  test "returns live-only rows with regime_inputs and tactical-first sorting", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    tactical_on_id = Ecto.UUID.generate()
    tactical_off_id = Ecto.UUID.generate()
    disabled_live_id = Ecto.UUID.generate()

    Repo.insert_all(LiveStrategy, [
      %{
        id: tactical_on_id,
        instrument: "EUR_USD",
        granularity: "M15",
        strategy_type: "trend",
        parameters: %{},
        enabled: true,
        curator_mode: "auto",
        max_position_size: "0.02",
        created_at: now,
        updated_at: now
      },
      %{
        id: tactical_off_id,
        instrument: "GBP_USD",
        granularity: "H1",
        strategy_type: "mean_reversion",
        parameters: %{},
        enabled: true,
        curator_mode: "auto",
        max_position_size: "0.01",
        created_at: now,
        updated_at: now
      },
      %{
        id: disabled_live_id,
        instrument: "AUD_USD",
        granularity: "H4",
        strategy_type: "breakout",
        parameters: %{},
        enabled: false,
        curator_mode: "auto",
        max_position_size: "0.015",
        created_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(Rule, [
      %{
        live_strategy_id: tactical_on_id,
        enabled: true,
        reason: "aligned_with_regime",
        regime_inputs: %{
          "composite" => "trending",
          "frames" => [
            %{"frame" => "H4", "regime" => "trending", "adx" => 35.7},
            %{"frame" => "H1", "regime" => "trending", "adx" => 28.1}
          ]
        },
        computed_at: now,
        inserted_at: now,
        updated_at: now
      },
      %{
        live_strategy_id: tactical_off_id,
        enabled: false,
        reason: "blocked_by_regime",
        regime_inputs: %{
          "composite" => "choppy",
          "frames" => [
            %{"frame" => "H4", "regime" => "choppy", "adx" => 13.2}
          ]
        },
        computed_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])

    case Repo.query("SELECT to_regclass('public.trading_config')") do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, _} ->
        Repo.query!(
          "INSERT INTO trading_config (key, value, updated_at) VALUES ('curator_enabled', 'true'::jsonb, NOW()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()"
        )

      {:error, _reason} ->
        :ok
    end

    conn = get(conn, "/api/rules/state")
    body = json_response(conn, 200)

    assert body["computed_at"]
    assert body["summary"] == %{"trading" => 1, "live" => 2, "curator_enabled" => true}

    assert [%{"live_strategy_id" => first_id} | _] = body["strategies"]
    assert first_id == tactical_on_id

    enabled_row = Enum.find(body["strategies"], &(&1["live_strategy_id"] == tactical_on_id))
    assert enabled_row["rules_enabled"] == true
    assert enabled_row["composite_regime"] == "trending"

    assert enabled_row["frames"] == [
             %{"frame" => "H4", "regime" => "trending", "adx" => 35.7},
             %{"frame" => "H1", "regime" => "trending", "adx" => 28.1}
           ]

    disabled_row = Enum.find(body["strategies"], &(&1["live_strategy_id"] == tactical_off_id))
    assert disabled_row["rules_enabled"] == false
    assert disabled_row["reason"] == "blocked_by_regime"

    refute Enum.any?(body["strategies"], &(&1["live_strategy_id"] == disabled_live_id))
  end
end
