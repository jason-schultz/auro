defmodule OpusWeb.CircuitBreakerController do
  use OpusWeb, :controller

  alias Opus.Repo
  alias Opus.Trading.Strategies
  alias Opus.Trading.Suspension

  import Ecto.Query

  def reset(conn, %{"id" => strategy_id}) do
    case Strategies.reset_suspension(strategy_id) do
      {:ok, cleared_count} ->
        json(conn, %{strategy_id: strategy_id, cleared_count: cleared_count})

      {:error, :invalid_id} ->
        conn |> put_status(400) |> json(%{error: "Invalid strategy id"})

      {:error, :none_open} ->
        conn |> put_status(404) |> json(%{error: "No active suspension found"})
    end
  end

  def open(conn, _params) do
    rows =
      Suspension.open_query()
      |> select([s], %{
        live_strategy_id: s.live_strategy_id,
        trigger_kind: s.trigger_kind,
        trigger_detail: s.trigger_detail,
        triggered_at: s.triggered_at
      })
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
end
