defmodule Opus.Settings.Setting do
  @moduledoc "One stored setting (`settings` table), by its `.env` name; see `Opus.Settings`."
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}
  schema "settings" do
    # Plain, or encrypted (`Opus.Settings.Secret`) for a secret field.
    field :value, :string
    field :updated_at, :utc_datetime_usec
    field :tested_at, :utc_datetime_usec
    field :test_result, :string
    field :test_ok, :boolean
  end
end
