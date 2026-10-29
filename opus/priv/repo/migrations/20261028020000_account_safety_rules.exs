defmodule Opus.Repo.Migrations.AccountSafetyRules do
  use Ecto.Migration

  @moduledoc """
  The account-level safety layer (`Opus.Trading.RulesEngine`):

  - `trading_config.account_limits`: the limits, editable later in the UI.
    - `drawdown_pause_pct` 10: stop every new entry when the account (NAV)
      falls 10% below its peak since `since` or the last reset.
    - `risk_budget_pct` 5: at most 5% of NAV at risk across open trades
      (each trade counts as the risk it was sized at, about 1% today).
    - `max_open_per_group` 2: at most 2 open trades per asset class
      (stock indices, metals, energy and farm goods, FX, bonds).
    - `since`: when the limits took effect, so the drawdown pause measures
      from today's NAV and not the older all-time peak.
  - `account_pauses`: drawdown pauses, each held until a person clears it.
  - `live_strategies.circuit_breaker_exempt`: a strategy the per-strategy
    circuit breaker leaves alone. Set for the NAS100 5-minute strategy
    (`2e0807d9-…`): its first five live trades were losses and it should keep
    trading. Elsewhere that row doesn't exist and the update does nothing.
  """

  def up do
    alter table(:live_strategies) do
      add_if_not_exists :circuit_breaker_exempt, :boolean, null: false, default: false
    end

    create_if_not_exists table(:account_pauses) do
      add :triggered_at, :utc_datetime_usec, null: false
      add :peak_nav, :float, null: false
      add :nav, :float, null: false
      add :limit_pct, :float, null: false
      add :cleared_at, :utc_datetime_usec
      add :cleared_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    execute """
    INSERT INTO trading_config (key, value, updated_at)
    VALUES (
      'account_limits',
      jsonb_build_object(
        'drawdown_pause_pct', 10,
        'risk_budget_pct', 5,
        'max_open_per_group', 2,
        'since', to_jsonb(now())
      ),
      now()
    )
    ON CONFLICT (key) DO NOTHING
    """

    execute """
    UPDATE live_strategies SET circuit_breaker_exempt = true
    WHERE id = '2e0807d9-a3fa-462d-9091-5e198103a4c2'
    """
  end

  def down do
    execute "DELETE FROM trading_config WHERE key = 'account_limits'"
    drop_if_exists table(:account_pauses)

    alter table(:live_strategies) do
      remove_if_exists :circuit_breaker_exempt, :boolean
    end
  end
end
