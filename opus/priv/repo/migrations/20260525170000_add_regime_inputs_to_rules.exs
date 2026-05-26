defmodule Opus.Repo.Migrations.AddRegimeInputsToRules do
  use Ecto.Migration

  def change do
    alter table(:rules) do
      add :regime_inputs, :map
    end
  end
end
