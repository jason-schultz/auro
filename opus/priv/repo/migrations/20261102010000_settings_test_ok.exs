defmodule Opus.Repo.Migrations.SettingsTestOk do
  use Ecto.Migration

  # Whether a setting's last Test passed, next to its words, so the
  # Settings page can show Working or Problem without reading the words.
  def change do
    alter table(:settings) do
      add :test_ok, :boolean
    end
  end
end
