defmodule Opus.Repo.Migrations.SafetySettingsAndDrift do
  use Ecto.Migration

  @moduledoc """
  The account safety rules become editable on the Safety page, and each
  live strategy gets a daily check against its backtest.

  - `trading_config.account_limits` gains the circuit breaker's limits,
    which were fixed in code until now: `breaker_losses` 5 (losing trades in
    a row), `breaker_drawdown_pct` 8 (trade returns summing below −8%…) and
    `breaker_window_days` 30 (…over 30 days). Same values as before.
  - `account_limit_changes`: every change to a limit or to a strategy's
    circuit-breaker exemption, with the old and new value, so a change can
    always be traced and undone.
  - `strategy_drift_checks`: the latest check of each live strategy's real
    trades against what its backtest calls normal (`Opus.Trading.Drift`).
  """

  def up do
    execute """
    UPDATE trading_config
    SET value = value || jsonb_build_object(
          'breaker_losses', 5,
          'breaker_drawdown_pct', 8,
          'breaker_window_days', 30
        ),
        updated_at = now()
    WHERE key = 'account_limits'
    """

    create_if_not_exists table(:account_limit_changes) do
      add :setting, :string, null: false
      add :subject, :string
      add :old_value, :string
      add :new_value, :string, null: false
      add :changed_at, :utc_datetime_usec, null: false
    end

    create_if_not_exists index(:account_limit_changes, [:changed_at])

    create_if_not_exists table(:strategy_drift_checks, primary_key: false) do
      add :live_strategy_id,
          references(:live_strategies, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :verdict, :string, null: false
      add :live_trades, :integer, null: false
      add :findings, {:array, :map}, null: false
      add :checked_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop_if_exists table(:strategy_drift_checks)
    drop_if_exists table(:account_limit_changes)

    execute """
    UPDATE trading_config
    SET value = value - 'breaker_losses' - 'breaker_drawdown_pct' - 'breaker_window_days'
    WHERE key = 'account_limits'
    """
  end
end
