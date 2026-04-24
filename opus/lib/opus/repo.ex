defmodule Opus.Repo do
  use Ecto.Repo,
    otp_app: :opus,
    adapter: Ecto.Adapters.Postgres
end
