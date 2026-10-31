defmodule OpusWeb.RulesController do
  use OpusWeb, :controller

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, Rule}

  import Ecto.Query

  def state(conn, _params) do
    rows =
      from(s in LiveStrategy,
        where: s.enabled == true,
        left_join: r in Rule,
        on: r.live_strategy_id == s.id,
        order_by: [
          desc: coalesce(r.enabled, false),
          asc: s.instrument,
          asc: s.granularity,
          asc: s.strategy_type
        ],
        select: %{
          live_strategy_id: s.id,
          instrument: s.instrument,
          granularity: s.granularity,
          strategy_type: s.strategy_type,
          rules_enabled: coalesce(r.enabled, false),
          reason: coalesce(r.reason, "no decision yet"),
          computed_at: r.computed_at,
          max_computed_at: fragment("MAX(?) OVER ()", r.computed_at)
        }
      )
      |> Repo.all()

    strategies = Enum.map(rows, &to_strategy_row/1)

    trading_count = Enum.count(strategies, & &1.rules_enabled)
    live_count = length(strategies)

    json(conn, %{
      computed_at: rows |> List.first() |> then(&(&1 && &1.max_computed_at)),
      summary: %{trading: trading_count, live: live_count},
      strategies: strategies
    })
  end

  defp to_strategy_row(row) do
    %{
      live_strategy_id: row.live_strategy_id,
      instrument: row.instrument,
      granularity: row.granularity,
      strategy_type: row.strategy_type,
      rules_enabled: row.rules_enabled,
      reason: row.reason,
      computed_at: row.computed_at
    }
  end
end
