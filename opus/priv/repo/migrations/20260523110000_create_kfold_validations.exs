defmodule Opus.Repo.Migrations.CreateKfoldValidations do
  use Ecto.Migration

  def change do
    create table(:kfold_validations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :live_strategy_id,
          references(:live_strategies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :fold_count, :integer, null: false
      add :pass_rate, :float, null: false
      add :median_sharpe, :float, null: false
      add :mean_sharpe, :float, null: false
      add :sharpe_std, :float, null: false
      add :min_sharpe, :float, null: false
      add :max_sharpe, :float, null: false
      add :worst_fold_dd, :float, null: false
      add :median_dd, :float, null: false
      add :total_trades_all_folds, :integer, null: false
      add :per_fold_stats, :map, null: false
      add :spec, :map, null: false
      add :validated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create index(:kfold_validations, [:live_strategy_id])
    create index(:kfold_validations, [:pass_rate])
    create index(:kfold_validations, [:median_sharpe])
  end
end
