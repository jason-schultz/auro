defmodule Opus.Trading.RulesEngineTest do
  use Opus.DataCase, async: false

  alias Opus.Repo
  alias Opus.Trading.{AccountPause, LiveStrategy, Rule, RulesEngine, Suspension}

  setup do
    Repo.delete_all(Suspension)
    Repo.delete_all(AccountPause)
    Repo.delete_all(Rule)
    Repo.delete_all(LiveStrategy)
    :ok
  end

  test "strategies of every type are clear to trade when no safety rule holds them" do
    ids = for type <- ~w(composite mean_reversion trend_following), do: insert_strategy(type)

    # Persisted before the push to Rust, which has no engine in tests.
    {:error, _} = RulesEngine.compute_and_push()

    for id <- ids do
      assert %Rule{enabled: true, reason: "clear: " <> _} = Repo.get(Rule, id)
    end
  end

  test "an open circuit-breaker suspension holds a strategy back until it is cleared" do
    held = insert_strategy("composite", "EUR_USD")
    cleared = insert_strategy("composite", "GBP_USD")
    suspend(held, nil)
    suspend(cleared, DateTime.utc_now())

    {:error, _} = RulesEngine.compute_and_push()

    assert %Rule{enabled: false, reason: "circuit_breaker: down 6%"} = Repo.get(Rule, held)
    assert %Rule{enabled: true} = Repo.get(Rule, cleared)
  end

  test "an account pause holds every strategy back" do
    ids = [insert_strategy("composite", "EUR_USD"), insert_strategy("composite", "GBP_USD")]

    Repo.insert!(%AccountPause{
      triggered_at: DateTime.utc_now(),
      peak_nav: 100_000.0,
      nav: 89_000.0,
      limit_pct: 10.0
    })

    {:error, _} = RulesEngine.compute_and_push()

    for id <- ids do
      assert %Rule{
               enabled: false,
               reason: "account_pause: NAV fell 11.0% from its peak of 100000"
             } =
               Repo.get(Rule, id)
    end
  end

  defp insert_strategy(type, instrument \\ "EUR_USD") do
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()

    Repo.insert_all(LiveStrategy, [
      %{
        id: id,
        strategy_type: type,
        instrument: instrument,
        granularity: "H1",
        parameters: %{},
        enabled: true,
        curator_mode: "pinned_on",
        created_at: now,
        updated_at: now
      }
    ])

    id
  end

  defp suspend(id, cleared_at) do
    %Suspension{}
    |> Suspension.changeset(%{
      live_strategy_id: id,
      triggered_at: DateTime.utc_now(),
      trigger_kind: "drawdown",
      trigger_detail: "down 6%",
      cleared_at: cleared_at
    })
    |> Repo.insert!()
  end
end
