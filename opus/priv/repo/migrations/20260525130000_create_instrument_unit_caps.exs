defmodule Opus.Repo.Migrations.CreateInstrumentUnitCaps do
  use Ecto.Migration

  def change do
    create table(:instrument_unit_caps, primary_key: false) do
      add :instrument, :string, primary_key: true, size: 20, null: false
      add :max_units, :bigint, null: false
      add :tier, :string, size: 10, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
