defmodule Opus.Repo.Migrations.AddDepthToStrategyConfigs do
  use Ecto.Migration

  def change do
    alter table(:strategy_configs) do
      add :depth, :integer, null: false, default: 0
    end
  end
end
