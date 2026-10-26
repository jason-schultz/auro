defmodule Opus.Repo.Migrations.AddRound3Round4Research do
  use Ecto.Migration

  @moduledoc """
  Research log rows written after the seed migration had already run:
  rounds 3 and 4, the manual crisis switch and the earnings-drift idea.
  """

  # {decided_on, area, status, title, summary, evidence, source}
  @entries [
    {~D[2026-10-26], "index", "failed",
     "Round 3: stress signals (credit, VIX, Sahm, two of three)",
     "De-risk the S&P 500 when real-world stress shows up, 1991–2026. No signal avoided all four crashes; shorting lost 53–93% on every signal.",
     "Sahm recession signal: quiet in all 7 contained scares, cut dot-com to −20.6% and 2008 to −9.3%, Sharpe 0.74 vs 0.69, worst DD −33.8% vs −55.5%; missed Covid (fired after the bottom) and 2022 (no recession). Credit and VIX cried wolf in 1998/2015/2018.",
     "research/round3_preregistration.md, research/results/round3_stress_signals.json, auro_be/examples/stress_signals.rs"},
    {~D[2026-10-26], "index", "parked", "Manual crisis switch",
     "A button in Opus for when the user judges it's a crisis. What it does is written down in advance (pause dip-buys, buy index puts); every flip is logged here so judgement can be scored against rules over time. Candidate trigger: the real-time Sahm rule.",
     "Back burner by user choice, Oct 26. Round 3 suggests the Sahm signal as one documented input.",
     "research/round3_preregistration.md"},
    {~D[2026-10-26], "index", "testing", "Round 4: volatility-managed index exposure",
     "Moreira & Muir 2017, no leverage: hold min(1, 0.16² ÷ last month's realized variance) of the S&P 500. Passed the crash test in all four crashes; missed the drawdown bar by 0.2 points. Adopted by the user on Oct 26 despite the miss; checked month by month from here.",
     "Crashes: dot-com −32.4% (vs −46.5%), 2008 −25.8% (−55.5%), Covid −21.4% (−33.8%), 2022 −17.0% (−24.3%). Sharpe 0.82 vs 0.69. Worst drawdown −37.2% vs a −37.0% bar. Average exposure 86%.",
     "research/round4_preregistration.md, research/results/round4_vol_managed.json, auro_be/examples/vol_managed.rs"},
    {~D[2026-10-26], "equities", "idea", "Post-earnings drift (PEAD)",
     "Stocks keep drifting for weeks in the direction of an earnings surprise. Long the beats, short or avoid the misses; daily manual trades on Wealthsimple.",
     "Blocked on data: the FMP free plan returns only the last 5 earnings per stock and no historical index membership. Needs 10+ years of surprises across hundreds of stocks.",
     "research tab, Oct 26"}
  ]

  def up do
    now = DateTime.utc_now()

    rows =
      Enum.map(@entries, fn {decided_on, area, status, title, summary, evidence, source} ->
        %{
          decided_on: decided_on,
          area: area,
          status: status,
          title: title,
          summary: summary,
          evidence: evidence,
          source: source,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all("research_entries", rows)
  end

  def down do
    titles = Enum.map(@entries, &elem(&1, 3))
    repo().query!("DELETE FROM research_entries WHERE title = ANY($1)", [titles])
  end
end
