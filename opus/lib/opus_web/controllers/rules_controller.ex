defmodule OpusWeb.RulesController do
  use OpusWeb, :controller

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, Rule, Strategies}

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
          regime_inputs: r.regime_inputs,
          max_computed_at: fragment("MAX(?) OVER ()", r.computed_at)
        }
      )
      |> Repo.all()

    strategies = Enum.map(rows, &to_strategy_row/1)

    trading_count = Enum.count(strategies, & &1.rules_enabled)
    live_count = length(strategies)
    curator_enabled = curator_enabled?()

    json(conn, %{
      computed_at: rows |> List.first() |> then(&(&1 && &1.max_computed_at)),
      summary: %{trading: trading_count, live: live_count, curator_enabled: curator_enabled},
      strategies: strategies
    })
  end

  defp to_strategy_row(row) do
    {composite_regime, frames} = Strategies.regime_summary(row.regime_inputs)

    %{
      live_strategy_id: row.live_strategy_id,
      instrument: row.instrument,
      granularity: row.granularity,
      strategy_type: row.strategy_type,
      rules_enabled: row.rules_enabled,
      reason: row.reason,
      computed_at: row.computed_at,
      composite_regime: composite_regime,
      frames: frames
    }
  end

  defp curator_enabled? do
    case Repo.query("SELECT to_regclass('public.trading_config')") do
      {:ok, %{rows: [[nil]]}} ->
        false

      {:ok, _} ->
        from(c in "trading_config",
          where: c.key == "curator_enabled",
          select: c.value
        )
        |> Repo.one()
        |> to_bool_value(false)

      {:error, _reason} ->
        false
    end
  end

  defp to_bool_value(nil, default), do: default
  defp to_bool_value(value, _default) when is_boolean(value), do: value

  defp to_bool_value(value, default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp to_bool_value(%{"value" => nested}, default), do: to_bool_value(nested, default)
  defp to_bool_value(%{value: nested}, default), do: to_bool_value(nested, default)
  defp to_bool_value(_value, default), do: default
end
