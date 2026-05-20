defmodule OpusWeb.CircuitBreakerController do
  use OpusWeb, :controller

  alias Opus.Repo
  alias Opus.Trading.RulesEngine
  alias Opus.Trading.Suspension

  import Ecto.Query

  def reset(conn, %{"id" => strategy_id}) do
    with {:ok, strategy_uuid} <- cast_uuid(strategy_id),
         {cleared_count, _} when cleared_count > 0 <- clear_open_suspensions(strategy_uuid) do
      RulesEngine.recompute()
      json(conn, %{strategy_id: strategy_uuid, cleared_count: cleared_count})
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid strategy id"})

      {0, _} ->
        conn
        |> put_status(404)
        |> json(%{error: "No active suspension found"})
    end
  end

  def open(conn, _params) do
    rows =
      from(s in Suspension,
        where: is_nil(s.cleared_at),
        order_by: [desc: s.triggered_at],
        select: %{
          live_strategy_id: s.live_strategy_id,
          trigger_kind: s.trigger_kind,
          trigger_detail: s.trigger_detail,
          triggered_at: s.triggered_at
        }
      )
      |> Repo.all()

    suspensions =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        Map.put_new(acc, row.live_strategy_id, %{
          trigger_kind: row.trigger_kind,
          trigger_detail: row.trigger_detail,
          triggered_at: row.triggered_at
        })
      end)

    json(conn, %{suspensions: suspensions})
  end

  defp clear_open_suspensions(strategy_id) do
    now = DateTime.utc_now()

    from(s in Suspension,
      where: s.live_strategy_id == ^strategy_id and is_nil(s.cleared_at)
    )
    |> Repo.update_all(
      set: [
        cleared_at: now,
        cleared_by: "manual",
        updated_at: now
      ]
    )
  end

  defp cast_uuid(strategy_id) do
    case Ecto.UUID.cast(strategy_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end
end
