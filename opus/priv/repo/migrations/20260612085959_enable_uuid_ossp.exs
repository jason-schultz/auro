defmodule Opus.Repo.Migrations.EnableUuidOssp do
  @moduledoc """
  `create_strategy_drafts` defaults ids to `uuid_generate_v4()`, which needs the
  uuid-ossp extension. In the shared dev DB a Rust migration creates it, but
  Opus's own test DB runs only Ecto migrations — so Opus enables it itself.
  Idempotent: a no-op wherever the extension already exists.
  """
  use Ecto.Migration

  def up, do: execute(~s(CREATE EXTENSION IF NOT EXISTS "uuid-ossp"))
  def down, do: :ok
end
