defmodule OpusWeb.JournalController do
  use OpusWeb, :controller

  import Ecto.Query

  alias Opus.Repo

  def kpis(conn, params) do
    now = DateTime.utc_now()

    with {:ok, to_ts} <- parse_ts(Map.get(params, "to"), now),
         {:ok, from_ts} <-
           parse_ts(Map.get(params, "from"), DateTime.add(to_ts, -30 * 86_400, :second)) do
      base_query = base_closed_trades_query(from_ts, to_ts, params)

      agg =
        from(lt in base_query,
          select: %{
            trade_count: fragment("COUNT(*)::int"),
            win_count: fragment("COUNT(*) FILTER (WHERE ? > 0)::int", lt.pnl),
            loss_count: fragment("COUNT(*) FILTER (WHERE ? < 0)::int", lt.pnl),
            breakeven_count:
              fragment("COUNT(*) FILTER (WHERE abs(COALESCE(?, 0)) <= 1)::int", lt.pnl),
            win_rate_pct:
              fragment(
                "COALESCE(ROUND((COUNT(*) FILTER (WHERE ? > 0)::numeric / NULLIF(COUNT(*), 0)::numeric) * 100, 1), 0)::float8",
                lt.pnl
              ),
            total_pnl_cad: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl),
            avg_win_cad:
              fragment("COALESCE(AVG(?) FILTER (WHERE ? > 0), 0)::float8", lt.pnl, lt.pnl),
            avg_loss_cad:
              fragment("COALESCE(AVG(?) FILTER (WHERE ? < 0), 0)::float8", lt.pnl, lt.pnl),
            profit_factor:
              fragment(
                "CASE WHEN COALESCE(SUM(?) FILTER (WHERE ? < 0), 0) = 0 THEN NULL ELSE (COALESCE(SUM(?) FILTER (WHERE ? > 0), 0) / ABS(SUM(?) FILTER (WHERE ? < 0)))::float8 END",
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl
              ),
            expectancy_cad:
              fragment(
                "((COALESCE(COUNT(*) FILTER (WHERE ? > 0)::float8 / NULLIF(COUNT(*), 0), 0) * COALESCE(AVG(?) FILTER (WHERE ? > 0), 0)) + (COALESCE(COUNT(*) FILTER (WHERE ? < 0)::float8 / NULLIF(COUNT(*), 0), 0) * COALESCE(AVG(?) FILTER (WHERE ? < 0), 0)))::float8",
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl,
                lt.pnl
              ),
            avg_mfe_pct: fragment("COALESCE(AVG(?), 0)::float8", lt.mfe_pct),
            avg_mae_pct: fragment("COALESCE(AVG(?), 0)::float8", lt.mae_pct)
          }
        )
        |> Repo.one()

      by_instrument =
        from(lt in base_query,
          group_by: lt.instrument,
          order_by: [desc: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl)],
          select: %{
            instrument: lt.instrument,
            pnl_cad: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl),
            trades: fragment("COUNT(*)::int"),
            win_rate_pct:
              fragment(
                "COALESCE(ROUND((COUNT(*) FILTER (WHERE ? > 0)::numeric / NULLIF(COUNT(*), 0)::numeric) * 100, 1), 0)::float8",
                lt.pnl
              )
          }
        )
        |> Repo.all()

      by_strategy_type =
        from(lt in base_query,
          join: ls in "live_strategies",
          on: ls.id == lt.live_strategy_id,
          group_by: ls.strategy_type,
          order_by: [desc: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl)],
          select: %{
            strategy_type: ls.strategy_type,
            pnl_cad: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl),
            trades: fragment("COUNT(*)::int"),
            win_rate_pct:
              fragment(
                "COALESCE(ROUND((COUNT(*) FILTER (WHERE ? > 0)::numeric / NULLIF(COUNT(*), 0)::numeric) * 100, 1), 0)::float8",
                lt.pnl
              )
          }
        )
        |> Repo.all()

      by_regime_at_entry =
        from(lt in base_query,
          group_by:
            fragment("COALESCE(NULLIF(split_part(?, ' ', 1), ''), 'unknown')", lt.regime_at_entry),
          order_by: [desc: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl)],
          select: %{
            regime:
              fragment(
                "COALESCE(NULLIF(split_part(?, ' ', 1), ''), 'unknown')",
                lt.regime_at_entry
              ),
            pnl_cad: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl),
            trades: fragment("COUNT(*)::int"),
            win_rate_pct:
              fragment(
                "COALESCE(ROUND((COUNT(*) FILTER (WHERE ? > 0)::numeric / NULLIF(COUNT(*), 0)::numeric) * 100, 1), 0)::float8",
                lt.pnl
              )
          }
        )
        |> Repo.all()

      json(conn, %{
        trade_count: agg.trade_count,
        win_count: agg.win_count,
        loss_count: agg.loss_count,
        breakeven_count: agg.breakeven_count,
        win_rate_pct: agg.win_rate_pct,
        total_pnl_cad: agg.total_pnl_cad,
        avg_win_cad: agg.avg_win_cad,
        avg_loss_cad: agg.avg_loss_cad,
        profit_factor: agg.profit_factor,
        expectancy_cad: agg.expectancy_cad,
        avg_mfe_pct: agg.avg_mfe_pct,
        avg_mae_pct: agg.avg_mae_pct,
        by_instrument: by_instrument,
        by_strategy_type: by_strategy_type,
        by_regime_at_entry: by_regime_at_entry
      })
    else
      {:error, msg} ->
        conn
        |> put_status(400)
        |> json(%{error: msg})
    end
  end

  defp parse_ts(nil, fallback), do: {:ok, fallback}

  defp parse_ts(value, _fallback) do
    case DateTime.from_iso8601(value) do
      {:ok, ts, _offset} -> {:ok, ts}
      _ -> {:error, "invalid timestamp: #{value}"}
    end
  end

  defp base_closed_trades_query(from_ts, to_ts, params) do
    from(lt in "live_trades",
      where: lt.status == "closed" and lt.exit_time >= ^from_ts and lt.exit_time <= ^to_ts
    )
    |> maybe_filter_strategy(params)
    |> maybe_filter_instrument(params)
  end

  defp maybe_filter_strategy(query, params) do
    case Map.get(params, "strategy_id") do
      nil -> query
      "" -> query
      strategy_id -> from(lt in query, where: lt.live_strategy_id == ^strategy_id)
    end
  end

  defp maybe_filter_instrument(query, params) do
    case Map.get(params, "instrument") do
      nil -> query
      "" -> query
      instrument -> from(lt in query, where: lt.instrument == ^instrument)
    end
  end
end
