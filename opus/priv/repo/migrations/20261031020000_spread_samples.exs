defmodule Opus.Repo.Migrations.SpreadSamples do
  use Ecto.Migration

  @moduledoc """
  Questrade bid/ask samples for markets tested as shares owned outright
  (`Opus.MarketData.SpreadWorker`): every 15 minutes in the regular
  session, away from the open and close. After the close each market's
  `instruments.spread_bps` becomes the median of its recent samples, so
  its tests charge its own measured spread instead of the broker's 10 bp
  placeholder.
  """

  def change do
    create table(:spread_samples) do
      add :instrument_id, references(:instruments, on_delete: :delete_all), null: false
      add :captured_at, :utc_datetime, null: false
      add :bid, :float, null: false
      add :ask, :float, null: false
      # (ask - bid) / mid, in basis points: one round trip's cost.
      add :spread_bps, :float, null: false
    end

    create index(:spread_samples, [:instrument_id, :captured_at])
  end
end
