defmodule Opus.Trading.CircuitBreakerTest do
  use Opus.DataCase, async: true
  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.CircuitBreaker
  alias Opus.Trading.LiveStrategy
  alias Opus.Trading.LiveTrade
  alias Opus.Trading.Suspension

  setup do
    from(s in Suspension) |> Repo.delete_all()
    from(t in LiveTrade) |> Repo.delete_all()
    from(s in LiveStrategy) |> Repo.delete_all()

    :ok
  end

  test "trips on consecutive losses and is idempotent while active suspension exists" do
    strategy_id = "11111111-1111-1111-1111-111111111111"
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: strategy_id,
      strategy_type: "composite",
      instrument: "EUR_USD",
      granularity: "H1",
      parameters: %{},
      enabled: true,
      created_at: now,
      updated_at: now
    })

    Enum.each(1..5, fn n ->
      Repo.insert!(%LiveTrade{
        live_strategy_id: strategy_id,
        status: "closed",
        pnl_percent: -0.01 * n,
        exit_time: DateTime.add(now, -n * 3_600, :second),
        created_at: now,
        updated_at: now
      })
    end)

    result = CircuitBreaker.run_cycle()
    assert result.triggered == 1

    result = CircuitBreaker.run_cycle()
    assert result.triggered == 0

    count = active_suspension_count(strategy_id)
    assert count == 1
  end

  test "trips on rolling drawdown over last 30d with minimum sample" do
    strategy_id = "22222222-2222-2222-2222-222222222222"
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: strategy_id,
      strategy_type: "mean_reversion",
      instrument: "GBP_USD",
      granularity: "H1",
      parameters: %{},
      enabled: true,
      created_at: now,
      updated_at: now
    })

    pnl_samples = [-0.04, -0.035, 0.01, -0.028, -0.022]

    Enum.with_index(pnl_samples, 1)
    |> Enum.each(fn {pnl, n} ->
      Repo.insert!(%LiveTrade{
        live_strategy_id: strategy_id,
        status: "closed",
        pnl_percent: pnl,
        exit_time: DateTime.add(now, -n * 86_400, :second),
        created_at: now,
        updated_at: now
      })
    end)

    result = CircuitBreaker.run_cycle()
    assert result.triggered == 1

    kind = latest_trigger_kind(strategy_id)
    assert kind == "rolling_drawdown"
  end

  test "skips manually disabled strategies" do
    strategy_id = "33333333-3333-3333-3333-333333333333"
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: strategy_id,
      strategy_type: "trend_following",
      instrument: "AUD_USD",
      granularity: "H1",
      parameters: %{},
      enabled: false,
      created_at: now,
      updated_at: now
    })

    Enum.each(1..5, fn n ->
      Repo.insert!(%LiveTrade{
        live_strategy_id: strategy_id,
        status: "closed",
        pnl_percent: -0.03,
        exit_time: DateTime.add(now, -n * 86_400, :second),
        created_at: now,
        updated_at: now
      })
    end)

    result = CircuitBreaker.run_cycle()
    assert result.triggered == 0

    count = active_suspension_count(strategy_id)
    assert count == 0
  end

  test "after a reset only newer trades count, so the same losses don't trip it again" do
    strategy_id = "44444444-4444-4444-4444-444444444444"
    now = DateTime.utc_now()
    insert_strategy(strategy_id, "XAU_USD")
    insert_losses(strategy_id, now, 5)

    assert CircuitBreaker.run_cycle().triggered == 1

    from(s in Suspension, where: s.live_strategy_id == ^strategy_id)
    |> Repo.update_all(set: [cleared_at: now, cleared_by: "manual"])

    assert CircuitBreaker.run_cycle().triggered == 0
    assert active_suspension_count(strategy_id) == 0
  end

  test "leaves a strategy marked exempt alone" do
    strategy_id = "55555555-5555-5555-5555-555555555555"
    now = DateTime.utc_now()
    insert_strategy(strategy_id, "NAS100_USD", circuit_breaker_exempt: true)
    insert_losses(strategy_id, now, 5)

    assert CircuitBreaker.run_cycle().triggered == 0
  end

  defp insert_strategy(id, instrument, attrs \\ []) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct!(
        %LiveStrategy{
          id: id,
          strategy_type: "composite",
          instrument: instrument,
          granularity: "H1",
          parameters: %{},
          enabled: true,
          created_at: now,
          updated_at: now
        },
        attrs
      )
    )
  end

  defp insert_losses(strategy_id, now, count) do
    Enum.each(1..count, fn n ->
      Repo.insert!(%LiveTrade{
        live_strategy_id: strategy_id,
        status: "closed",
        pnl_percent: -0.005,
        exit_time: DateTime.add(now, -n * 3_600, :second),
        created_at: now,
        updated_at: now
      })
    end)
  end

  defp active_suspension_count(strategy_id) do
    from(s in Suspension,
      where: s.live_strategy_id == ^strategy_id and is_nil(s.cleared_at),
      select: count(s.id)
    )
    |> Repo.one()
  end

  defp latest_trigger_kind(strategy_id) do
    from(s in Suspension,
      where: s.live_strategy_id == ^strategy_id and is_nil(s.cleared_at),
      order_by: [desc: s.triggered_at],
      limit: 1,
      select: s.trigger_kind
    )
    |> Repo.one()
  end
end
