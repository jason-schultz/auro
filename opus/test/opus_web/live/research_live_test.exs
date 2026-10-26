defmodule OpusWeb.ResearchLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  test "lists entries with their verdict, numbers and source", %{conn: conn} do
    entry =
      entry!(%{
        title: "RSI(2) dip-buy",
        status: "worked",
        summary: "Live on three indices.",
        evidence: "Lockbox Sharpe +0.72",
        source: "memory: finding_lockbox_verdict_oct17",
        decided_on: ~D[2026-10-17]
      })

    {:ok, _view, html} = live(conn, ~p"/research")

    assert html =~ ~s(id="entry-#{entry.id}")
    assert html =~ "Live on three indices."
    assert html =~ "Lockbox Sharpe +0.72"
    assert html =~ "finding_lockbox_verdict_oct17"
    assert html =~ "Oct 17, 2026"
    assert html =~ "Printed"
  end

  test "status chips narrow the list", %{conn: conn} do
    worked = entry!(%{title: "Worked one", status: "worked"})
    failed = entry!(%{title: "Failed one", status: "failed"})
    {:ok, view, _html} = live(conn, ~p"/research")

    html = view |> element("button[phx-value-status=failed]") |> render_click()
    assert html =~ ~s(id="entry-#{failed.id}")
    refute html =~ ~s(id="entry-#{worked.id}")

    html = view |> element("button[phx-value-status=parked]") |> render_click()
    assert html =~ "Nothing matches."
  end

  test "search narrows the list", %{conn: conn} do
    gold = entry!(%{title: "Gold IFVG"})
    oil = entry!(%{title: "Brent-WTI spread"})
    {:ok, view, _html} = live(conn, ~p"/research")

    html = view |> form("#search-form", search: "gold") |> render_change()
    assert html =~ ~s(id="entry-#{gold.id}")
    refute html =~ ~s(id="entry-#{oil.id}")
  end

  test "logs a new entry from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/research")

    html =
      view
      |> form("#add-form",
        entry: %{
          "title" => "Trend book",
          "area" => "multi",
          "status" => "testing",
          "summary" => "Crash insurance."
        }
      )
      |> render_submit()

    assert html =~ "Logged “Trend book”."
    assert [%{title: "Trend book", status: "testing"}] = Research.list()
  end

  test "a missing verdict line keeps the form and logs nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/research")

    view
    |> form("#add-form", entry: %{"title" => "Half an idea", "area" => "fx", "status" => "idea"})
    |> render_submit()

    assert Research.list() == []
  end

  test "changing the status moves the entry", %{conn: conn} do
    entry = entry!(%{title: "Trend book", status: "testing"})
    {:ok, view, _html} = live(conn, ~p"/research")

    view |> form("#status-#{entry.id}", status: "failed") |> render_change()

    assert %{status: "failed", decided_on: today} = Research.get!(entry.id)
    assert today == Date.utc_today()
  end
end
