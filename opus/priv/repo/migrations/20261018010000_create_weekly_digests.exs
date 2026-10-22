defmodule Opus.Repo.Migrations.CreateWeeklyDigests do
  use Ecto.Migration

  # One row per Monday-to-Sunday week: the Journal's numbers frozen for review
  # (see Opus.Journal.DigestWorker).
  def change do
    create_if_not_exists table(:weekly_digests, primary_key: false) do
      add(:week_start, :date, primary_key: true)
      add(:week_end, :date, null: false)
      add(:payload, :map, null: false)
      add(:generated_at, :utc_datetime_usec, null: false)
    end
  end
end
