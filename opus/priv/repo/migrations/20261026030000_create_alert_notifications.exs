defmodule Opus.Repo.Migrations.CreateAlertNotifications do
  use Ecto.Migration

  @moduledoc """
  Which dashboard alerts were sent to Discord (`Opus.Dashboard.NotifyWorker`),
  so each is sent once while it stays on the dashboard. `seen_at` is the last
  check that still showed it; a row unseen for an hour is forgotten, so the
  alert is sent again if it comes back.
  """

  def change do
    create table(:alert_notifications, primary_key: false) do
      add :key, :text, primary_key: true
      add :sent_at, :utc_datetime_usec, null: false
      add :seen_at, :utc_datetime_usec, null: false
    end

    create index(:alert_notifications, [:seen_at])
  end
end
