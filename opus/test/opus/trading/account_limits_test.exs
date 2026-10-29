defmodule Opus.Trading.AccountLimitsTest do
  use Opus.DataCase, async: false

  alias Opus.Repo
  alias Opus.Trading.{AccountLimitChange, AccountLimits, LiveStrategy}

  @id "cccccccc-0000-0000-0000-000000000001"

  setup do
    Repo.delete_all(AccountLimitChange)
    limits = AccountLimits.get()

    %{
      limits: limits,
      form: Map.new(AccountLimits.keys(), &{Atom.to_string(&1), to_string(limits[&1])})
    }
  end

  test "the limits include the circuit breaker's", %{limits: limits} do
    assert %{breaker_losses: _, breaker_drawdown_pct: _, breaker_window_days: _} = limits
  end

  test "an unchanged form changes nothing", %{limits: limits, form: form} do
    assert AccountLimits.diff(limits, form) == {:ok, []}
  end

  test "raising a limit loosens it, lowering one doesn't, and the window is neither",
       %{limits: limits, form: form} do
    form =
      form
      |> Map.put("risk_budget_pct", to_string(limits.risk_budget_pct + 1))
      |> Map.put("max_open_per_group", to_string(limits.max_open_per_group - 1))
      |> Map.put("breaker_window_days", to_string(limits.breaker_window_days + 10))

    {:ok, changes} = AccountLimits.diff(limits, form)
    by_key = Map.new(changes, &{&1.key, &1.loosens?})

    assert by_key == %{
             risk_budget_pct: true,
             max_open_per_group: false,
             breaker_window_days: false
           }
  end

  test "a value out of range or not a number is refused with the range", %{
    limits: limits,
    form: form
  } do
    form = form |> Map.put("drawdown_pause_pct", "90") |> Map.put("breaker_losses", "lots")

    assert {:error, errors} = AccountLimits.diff(limits, form)
    assert errors.drawdown_pause_pct =~ "from 1 to 50"
    assert errors.breaker_losses =~ "from 2 to 20"
  end

  test "saving writes the limits and logs each change", %{limits: limits, form: form} do
    {:ok, changes} = AccountLimits.diff(limits, Map.put(form, "risk_budget_pct", "4"))
    {:ok, saved} = AccountLimits.save(changes)

    assert saved.risk_budget_pct == 4.0
    assert saved.drawdown_pause_pct == limits.drawdown_pause_pct

    assert [%{setting: "risk_budget_pct", new_value: "4.0", old_value: old}] =
             AccountLimits.changes()

    assert old == to_string(limits.risk_budget_pct)
  end

  test "exempting a strategy from the breaker is logged against it" do
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: @id,
      strategy_type: "composite",
      instrument: "SPX500_USD",
      granularity: "D",
      parameters: %{"strategy_name" => "Dip-buy"},
      enabled: true,
      created_at: now,
      updated_at: now
    })

    assert AccountLimits.set_exempt(@id, true) == {:ok, true}
    assert Repo.get!(LiveStrategy, @id).circuit_breaker_exempt

    assert [
             %{
               setting: "circuit_breaker_exempt",
               subject: "Dip-buy on SPX500_USD",
               new_value: "true"
             }
           ] =
             AccountLimits.changes()
  end

  test "groups put FX majors and crosses together" do
    instrument!("EUR_USD", "fx_major")
    instrument!("AUD_CAD", "fx_cross")
    instrument!("SPX500_USD", "index")

    groups = AccountLimits.groups(["EUR_USD", "AUD_CAD", "SPX500_USD"])
    assert groups["EUR_USD"] == "fx"
    assert groups["AUD_CAD"] == "fx"
    assert groups["SPX500_USD"] == "index"
  end

  defp instrument!(symbol, asset_class) do
    Repo.query!(
      "INSERT INTO instruments (symbol, oanda_symbol, exchange, currency, asset_class) VALUES ($1, $1, 'OANDA', 'USD', $2)",
      [symbol, asset_class]
    )
  end
end
