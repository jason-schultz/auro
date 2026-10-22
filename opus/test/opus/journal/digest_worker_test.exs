defmodule Opus.Journal.DigestWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Journal.{Digest, DigestWorker}
  alias Opus.Repo

  setup do
    Repo.query!("DELETE FROM weekly_digests")
    :ok
  end

  test "previous_week is the Monday-to-Sunday week before the given instant" do
    # Monday Oct 19 2026 12:00 UTC → the week of Oct 12.
    assert Digest.previous_week(~U[2026-10-19 12:00:00Z]) == {~D[2026-10-12], ~D[2026-10-18]}
    # Mid-week asks for the same week.
    assert Digest.previous_week(~U[2026-10-21 03:00:00Z]) == {~D[2026-10-12], ~D[2026-10-18]}
    # Sunday still belongs to the current week, so last week is the one before.
    assert Digest.previous_week(~U[2026-10-18 23:00:00Z]) == {~D[2026-10-05], ~D[2026-10-11]}
  end

  test "perform freezes last week's numbers and is idempotent per week" do
    assert :ok = perform_job(DigestWorker, %{"week_start" => "2026-10-05"})
    assert :ok = perform_job(DigestWorker, %{"week_start" => "2026-10-05"})

    assert [digest] = Repo.all(Digest)
    assert digest.week_start == ~D[2026-10-05]
    assert digest.week_end == ~D[2026-10-11]

    assert %{"kpis" => %{"trade_count" => 0}, "strategies" => _, "execution_quality" => _} =
             digest.payload
  end
end
