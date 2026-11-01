defmodule Opus.Repo.Migrations.Settings do
  use Ecto.Migration

  @moduledoc """
  The Settings page's store (`Opus.Settings`): keys, accounts and addresses
  by their `.env` name, a secret one encrypted (`enc:v1:…`, AES-256-GCM under
  AURO_SECRETS_KEY). Both apps read a stored value ahead of `.env`; the
  engine checks the table exists at start-up.
  """

  def change do
    create table(:settings, primary_key: false) do
      add :name, :text, primary_key: true
      add :value, :text, null: false
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
      add :tested_at, :timestamptz
      add :test_result, :text
    end
  end
end
