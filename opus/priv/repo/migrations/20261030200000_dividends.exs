defmodule Opus.Repo.Migrations.Dividends do
  use Ecto.Migration

  @moduledoc """
  Cash dividends, for testing shares held at a broker with no overnight
  cost (Wealthsimple): the stored bars are split-adjusted but not
  dividend-adjusted, so without these a long hold is understated by its
  yield (about 1.5% a year on SPY, 3–4% on TLT).

  `dividends`: one row per payment, by ex-dividend date, from Massive
  (`/v3/reference/dividends`; its history starts around 2003–2007
  depending on the fund). A long held over the ex-date is paid
  `cash_amount` a share.

  `instruments.dividends_checked_at`: when the dividends were last fetched.
  A share market's tests need it: fetched with no rows means the fund pays
  none (GLD); never fetched means unknown, and the test is refused. Tests
  start at the first recorded ex-date, so no stretch is graded without its
  dividends.
  """

  def change do
    create table(:dividends) do
      add :instrument_id, references(:instruments, on_delete: :delete_all), null: false
      add :ex_date, :date, null: false
      add :pay_date, :date
      add :cash_amount, :float, null: false
      add :frequency, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:dividends, [:instrument_id, :ex_date])

    alter table(:instruments) do
      add :dividends_checked_at, :utc_datetime
    end
  end
end
