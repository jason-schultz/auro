defmodule OpusWeb.CircuitBreakerControllerTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.Suspension

  setup %{conn: _conn} do
    from(s in Suspension) |> Repo.delete_all()
    :ok
  end

  test "resets active suspension and triggers rules recompute", %{conn: conn} do
    strategy_id = "44444444-4444-4444-4444-444444444444"
    now = DateTime.utc_now()

    %Suspension{}
    |> Suspension.changeset(%{
      live_strategy_id: strategy_id,
      triggered_at: now,
      trigger_kind: "consecutive_losses",
      trigger_detail: "4 losing trades in a row"
    })
    |> Repo.insert!()

    conn = post(conn, "/api/strategy-suspensions/#{strategy_id}/reset")

    assert %{"strategy_id" => ^strategy_id, "cleared_count" => 1} = json_response(conn, 200)

    count =
      from(s in Suspension,
        where: s.live_strategy_id == ^strategy_id and is_nil(s.cleared_at),
        select: count(s.id)
      )
      |> Repo.one()

    assert count == 0
  end

  test "returns 404 when there is no active suspension", %{conn: conn} do
    strategy_id = "55555555-5555-5555-5555-555555555555"

    conn = post(conn, "/api/strategy-suspensions/#{strategy_id}/reset")

    assert %{"error" => "No active suspension found"} = json_response(conn, 404)
  end

  test "returns 400 for invalid strategy id", %{conn: conn} do
    strategy_id = "not-a-uuid"
    conn = post(conn, "/api/strategy-suspensions/#{strategy_id}/reset")

    assert %{"error" => "Invalid strategy id"} = json_response(conn, 400)
  end
end
