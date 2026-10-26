defmodule Opus.Repo.Migrations.CreateResearchEntries do
  use Ecto.Migration

  @moduledoc """
  The research log behind the Research page: one row per idea or test, with
  its verdict (`idea`, `testing`, `worked`, `failed`, `parked` = worth
  another look later), the numbers that decided it and where the full notes
  live. Opus-only; Rust never reads it.
  """

  def change do
    create table(:research_entries) do
      add :title, :string, null: false
      add :area, :string, size: 16, null: false
      add :status, :string, size: 12, null: false, default: "idea"
      add :summary, :text, null: false
      add :details, :text
      add :evidence, :text
      add :source, :text
      add :decided_on, :date

      timestamps(type: :utc_datetime_usec)
    end

    create index(:research_entries, [:status])
  end
end
