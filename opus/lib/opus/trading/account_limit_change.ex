defmodule Opus.Trading.AccountLimitChange do
  @moduledoc """
  One change to an account safety setting (`Opus.Trading.AccountLimits`):
  which setting, the strategy it was about for an exemption (`subject`),
  and the value before and after, as written.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "account_limit_changes" do
    field :setting, :string
    field :subject, :string
    field :old_value, :string
    field :new_value, :string
    field :changed_at, :utc_datetime_usec
  end
end
