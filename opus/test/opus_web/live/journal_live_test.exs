defmodule OpusWeb.JournalLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Journal.DigestWorker
  alias Opus.Repo

  setup do
    Repo.query!("DELETE FROM live_trades")
    Repo.query!("DELETE FROM weekly_digests")
    :ok
  end

  test "renders every review section with an empty book", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal")

    for heading <- ~w(Strategies Execution\ quality Holdout\ verdicts Suspended Weekly\ digests) do
      assert html =~ heading
    end

    assert html =~ "First digest lands next Monday."
  end

  test "lists a frozen weekly digest", %{conn: conn} do
    {:ok, digest} = DigestWorker.generate(~D[2026-10-05])
    assert digest.week_end == ~D[2026-10-11]

    {:ok, _view, html} = live(conn, ~p"/journal")

    assert html =~ "2026-10-05"
    refute html =~ "First digest lands next Monday."
  end
end
