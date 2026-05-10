defmodule Opus.Repo.Migrations.AddGenerationPromptToStrategyConfigs do
  use Ecto.Migration

  def change do
    alter table(:strategy_configs) do
      add :generation_prompt, :text, null: true
    end
  end
end
