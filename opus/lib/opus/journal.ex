defmodule Opus.Journal do
  @moduledoc """
  Forward-test review: what the live book did over a window.

  One set of queries feeds the JSON API (`OpusWeb.JournalController`), the
  Journal page (`OpusWeb.JournalLive`) and the Monday digest
  (`Opus.Journal.DigestWorker`). Everything is read from the tables Rust
  writes (`live_trades`, `live_strategies`) plus the pipeline's holdout
  verdicts and the circuit breaker's open suspensions.
  """

  import Ecto.Query

  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation}
  alias Opus.Repo
  alias Opus.Trading.{ExecutionQuality, LiveTrade, Suspension}

  @type window :: {DateTime.t(), DateTime.t()}

  @doc "Default review windows: 30 days for P&L, 90 for execution quality."
  @spec window(non_neg_integer(), DateTime.t()) :: window()
  def window(days, to \\ DateTime.utc_now()), do: {DateTime.add(to, -days * 86_400, :second), to}

  @doc """
  Closed-trade KPIs for the window, with breakdowns by instrument, strategy
  type and regime at entry. `filters` may carry `"strategy_id"` and/or
  `"instrument"`.
  """
  @spec kpis(window(), map()) :: map()
  def kpis({from_ts, to_ts}, filters \\ %{}) do
    base_query = base_closed_trades_query(from_ts, to_ts, filters)

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

    Map.merge(agg, %{
      by_instrument: by_instrument,
      by_strategy_type: by_strategy_type,
      by_regime_at_entry: by_regime_at_entry
    })
  end

  @doc """
  Live fills against the fills the backtest assumed, per strategy, for trades
  entered in the window. Positive slippage = worse than the backtest.
  """
  @spec execution_quality(window()) :: [map()]
  def execution_quality({from_ts, to_ts}) do
    trades =
      from(lt in LiveTrade,
        where: lt.entry_time >= ^from_ts and lt.entry_time <= ^to_ts,
        where: not is_nil(lt.expected_entry_price),
        select: %{
          live_strategy_id: lt.live_strategy_id,
          direction: lt.direction,
          entry_price: lt.entry_price,
          exit_price: lt.exit_price,
          expected_entry_price: lt.expected_entry_price,
          entry_spread: lt.entry_spread,
          expected_exit_price: lt.expected_exit_price,
          exit_spread: lt.exit_spread
        }
      )
      |> Repo.all()

    labels = strategy_labels()

    trades
    |> ExecutionQuality.summarize()
    |> Enum.map(fn row -> Map.merge(row, Map.get(labels, row.live_strategy_id, %{})) end)
  end

  @doc """
  Per-strategy leaderboard over the window, driven from `live_strategies` so
  new strategies appear with zeros, plus each strategy's current open-trade
  count (not window-bound).
  """
  @spec strategy_performance(window()) :: [map()]
  def strategy_performance({from_ts, to_ts}) do
    closed =
      from(ls in "live_strategies",
        left_join: lt in "live_trades",
        on:
          lt.live_strategy_id == ls.id and lt.status == "closed" and
            lt.exit_time >= ^from_ts and lt.exit_time <= ^to_ts,
        group_by: [ls.id, ls.instrument, ls.granularity, ls.strategy_type, ls.enabled],
        order_by: [desc: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl)],
        select: %{
          # Schemaless query: cast the raw uuid bytes so Jason can encode it.
          strategy_id: type(ls.id, Ecto.UUID),
          instrument: ls.instrument,
          granularity: ls.granularity,
          strategy_type: ls.strategy_type,
          enabled: ls.enabled,
          trades: fragment("COUNT(?)::int", lt.oanda_trade_id),
          win_rate_pct:
            fragment(
              "COALESCE(ROUND((COUNT(*) FILTER (WHERE ? > 0)::numeric / NULLIF(COUNT(?), 0)::numeric) * 100, 1), 0)::float8",
              lt.pnl,
              lt.oanda_trade_id
            ),
          pnl_cad: fragment("COALESCE(SUM(?), 0)::float8", lt.pnl),
          avg_pnl_pct: fragment("COALESCE(AVG(?), 0)::float8", lt.pnl_percent)
        }
      )
      |> Repo.all()

    open_counts =
      from(lt in "live_trades",
        where: lt.status == "open",
        group_by: lt.live_strategy_id,
        select: {type(lt.live_strategy_id, Ecto.UUID), count(lt.oanda_trade_id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(closed, fn row ->
      Map.put(row, :open_trades, Map.get(open_counts, row.strategy_id, 0))
    end)
  end

  @doc "Every holdout verdict the pipeline has issued, newest first."
  @spec holdout_verdicts() :: [map()]
  def holdout_verdicts do
    from(e in StrategyEvaluation,
      join: c in StrategyConfig,
      on: c.id == e.strategy_config_id,
      where: e.stage == "holdout",
      order_by: [desc: e.evaluated_at],
      select: %{
        config_id: c.id,
        instrument: c.instrument,
        granularity: c.granularity,
        strategy_type: c.strategy_type,
        status: e.status,
        stats: e.stats,
        failure_reason: e.failure_reason,
        evaluated_at: e.evaluated_at
      }
    )
    |> Repo.all()
  end

  @doc "Strategies the circuit breaker has suspended and nobody has reset, with their labels."
  @spec open_suspensions() :: [map()]
  def open_suspensions do
    labels = strategy_labels()

    Suspension.open_query()
    |> select([s], %{
      live_strategy_id: s.live_strategy_id,
      trigger_kind: s.trigger_kind,
      trigger_detail: s.trigger_detail,
      triggered_at: s.triggered_at
    })
    |> Repo.all()
    |> Enum.uniq_by(& &1.live_strategy_id)
    |> Enum.map(fn row -> Map.merge(row, Map.get(labels, row.live_strategy_id, %{})) end)
  end

  defp strategy_labels do
    from(ls in "live_strategies",
      select:
        {type(ls.id, Ecto.UUID),
         %{
           strategy_type: ls.strategy_type,
           instrument: ls.instrument,
           granularity: ls.granularity
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp base_closed_trades_query(from_ts, to_ts, filters) do
    from(lt in "live_trades",
      where: lt.status == "closed" and lt.exit_time >= ^from_ts and lt.exit_time <= ^to_ts
    )
    |> maybe_filter(:live_strategy_id, Map.get(filters, "strategy_id"))
    |> maybe_filter(:instrument, Map.get(filters, "instrument"))
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [lt], field(lt, ^field) == ^value)
end
