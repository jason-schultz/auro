defmodule Opus.Dashboard.FeedTest do
  use Opus.DataCase, async: false

  alias Opus.Dashboard.Feed

  setup do
    pid = start_supervised!(Feed)
    Ecto.Adapters.SQL.Sandbox.allow(Opus.Repo, self(), pid)
    :ok
  end

  test "a change is gathered once and pushed to open dashboards" do
    Feed.subscribe()

    # Changes landing together make one gather.
    Feed.changed()
    Feed.changed()
    assert_receive {:dashboard, %{input: _, books: _}}, 5_000
    refute_receive {:dashboard, _}, 2_500
  end

  test "a finished job counts as a change" do
    Feed.subscribe()
    :telemetry.execute([:oban, :job, :stop], %{duration: 1}, %{job: %{queue: "alerts"}})
    assert_receive {:dashboard, _}, 5_000
  end
end
