defmodule Opus.Repo.Migrations.CreateStrategyDrafts do
  use Ecto.Migration

  def change do
    create table(:strategy_drafts, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()"))
      add(:name, :text, null: false)
      # Instrument-agnostic editor state: components, entry/exit wiring,
      # stop, sizing, max_hold_bars. Instrument/granularity are a preview
      # context, stored only as last-used defaults.
      add(:definition, :map, null: false)
      add(:last_instrument, :text)
      add(:last_granularity, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:strategy_drafts, [:updated_at]))
  end
end
