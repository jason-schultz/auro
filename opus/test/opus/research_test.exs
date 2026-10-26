defmodule Opus.ResearchTest do
  use Opus.DataCase, async: true

  alias Opus.Repo
  alias Opus.Research
  alias Opus.Research.Entry

  # The seed migration fills the log; start each test from an empty one.
  setup do
    Repo.delete_all(Entry)
    :ok
  end

  defp entry!(attrs) do
    {:ok, entry} =
      attrs
      |> Enum.into(%{title: "An idea", area: "index", status: "idea", summary: "Maybe."})
      |> Research.create()

    entry
  end

  test "create rejects an unknown status or area" do
    assert {:error, changeset} =
             Research.create(%{title: "x", area: "crypto", status: "moon", summary: "y"})

    assert %{status: [_], area: [_]} = errors_on(changeset)
  end

  test "list filters by status and searches the title, summary and evidence" do
    entry!(%{title: "RSI(2) dip-buy", status: "worked", evidence: "Sharpe +0.72"})
    entry!(%{title: "Gold IFVG", status: "failed", summary: "Spread kills it."})

    assert [%{title: "RSI(2) dip-buy"}] = Research.list(status: "worked")
    assert [%{title: "Gold IFVG"}] = Research.list(search: "spread")
    assert [%{title: "RSI(2) dip-buy"}] = Research.list(search: "0.72")
    assert length(Research.list(status: "all")) == 2
  end

  test "lists the latest verdicts first and undecided ideas last" do
    entry!(%{title: "Undecided"})
    entry!(%{title: "Older", status: "failed", decided_on: ~D[2026-06-01]})
    entry!(%{title: "Newer", status: "failed", decided_on: ~D[2026-10-17]})

    assert Enum.map(Research.list(), & &1.title) == ["Newer", "Older", "Undecided"]
  end

  test "counts has every status, zero when empty" do
    entry!(%{status: "failed"})
    entry!(%{status: "failed"})

    assert Research.counts() == %{
             "idea" => 0,
             "testing" => 0,
             "worked" => 0,
             "failed" => 2,
             "parked" => 0
           }
  end

  test "reaching a verdict dates an undated entry, and keeps an existing date" do
    {:ok, worked} = entry!(%{}) |> Research.set_status("worked")
    assert worked.decided_on == Date.utc_today()

    {:ok, testing} = entry!(%{}) |> Research.set_status("testing")
    assert testing.decided_on == nil

    dated = entry!(%{status: "testing", decided_on: ~D[2026-10-26]})
    assert {:ok, %{decided_on: ~D[2026-10-26]}} = Research.set_status(dated, "failed")
  end
end
