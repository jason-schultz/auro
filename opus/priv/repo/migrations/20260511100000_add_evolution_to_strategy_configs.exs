defmodule Opus.Repo.Migrations.AddEvolutionToStrategyConfigs do
  use Ecto.Migration

  def change do
    alter table(:strategy_configs) do
      add :evo_generation, :integer
      add :lineage_id, :uuid
      add :score, :float
    end

    create index(:strategy_configs, [:lineage_id, :evo_generation])
  end
end
