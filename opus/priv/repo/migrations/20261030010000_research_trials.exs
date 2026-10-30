defmodule Opus.Repo.Migrations.ResearchTrials do
  use Ecto.Migration

  @moduledoc """
  Markets an idea was tried on outside the pipeline (research sweeps in
  auro_research and offline harnesses), so the deflated Sharpe counts them.
  N for a family is the number of distinct markets tried: the pipeline's
  configs with a finished backtest together with every entry of `markets`
  here, each "INSTRUMENT@GRANULARITY" (`"SPX500_USD@D"`) counted once.
  Settings variants on one market are one try. `family` is the engine's
  family key, the sorted block types joined with "+"
  (`engine::pipeline::deflated_sharpe::family`).

  The seed rows are the research whose notes name the markets. Notes that
  give only a count (the Oct 16 sweep's 10,688 cells, the Oct 17 M5 sweep,
  the Oct 13 class screen's FX, commodity and Turtle groups, the round 2
  trend book's universe) are not seeded: their markets aren't written down.
  """

  @indices_daily ~w(US30_USD@D NAS100_USD@D SPX500_USD@D DE30_EUR@D UK100_GBP@D AU200_AUD@D JP225_USD@D EU50_EUR@D)
  @us_indices_m5 ~w(NAS100_USD@M5 SPX500_USD@M5 US30_USD@M5)

  @seed [
    {"MaFilter+RsiReversion", @indices_daily,
     "Connors RSI(2) dip-buy on the 8 indices, daily: the 54-combination robustness sweep (RSI period, entry level, trend average, exit average), and the short-only and both-sides variants on the same markets",
     "memory/finding_connors_rsi2_indices.md", ~D[2026-06-02]},
    {"NoiseArea", @us_indices_m5,
     "Noise-area intraday momentum, M5: a 25-combination lookback × band grid on NAS100, and the same rules on SPX500 and US30",
     "memory/finding_intraday_noise_area_nas100.md", ~D[2026-10-16]},
    {"NoiseArea+Volatility", ~w(NAS100_USD@M5),
     "Noise-area on NAS100 M5 split by a volatility filter (low, mid, high terciles)",
     "memory/finding_explore_round1_oct16.md", ~D[2026-10-16]},
    {"EventWindow", @us_indices_m5,
     "Pre-FOMC drift: long from the day-before afternoon to the announcement, entry and exit times varied, on NAS100, SPX500 and US30 M5",
     "memory/finding_explore_round1_oct16.md", ~D[2026-10-16]}
  ]

  def up do
    create table(:research_trials) do
      add(:family, :text, null: false)
      add(:markets, {:array, :text}, null: false)
      add(:note, :text, null: false)
      add(:source, :text, null: false)
      add(:recorded_on, :date, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:research_trials, [:family]))

    create(constraint(:research_trials, :markets_present, check: "cardinality(markets) > 0"))

    flush()

    now = DateTime.utc_now()

    repo().insert_all(
      "research_trials",
      for {family, markets, note, source, recorded_on} <- @seed do
        %{
          family: family,
          markets: markets,
          note: note,
          source: source,
          recorded_on: recorded_on,
          inserted_at: now,
          updated_at: now
        }
      end
    )
  end

  def down do
    drop(table(:research_trials))
  end
end
