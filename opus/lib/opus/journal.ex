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
  alias Opus.Journal.TradeStory
  alias Opus.Trading.{ExecutionQuality, LiveStrategy, LiveTrade, Strategies, Suspension}

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
          # Wins and losses by the money made, or by the price move where
          # an old trade never had its money recorded (pnl NULL, May–Aug):
          # a stop-out is a loss either way, never a scratch.
          trade_count: fragment("COUNT(*)::int"),
          win_count:
            fragment("COUNT(*) FILTER (WHERE COALESCE(?, ?) > 0)::int", lt.pnl, lt.pnl_percent),
          loss_count:
            fragment("COUNT(*) FILTER (WHERE COALESCE(?, ?) < 0)::int", lt.pnl, lt.pnl_percent),
          breakeven_count: fragment("COUNT(*) FILTER (WHERE abs(?) <= 1)::int", lt.pnl),
          win_rate_pct:
            fragment(
              "COALESCE(ROUND((COUNT(*) FILTER (WHERE COALESCE(?, ?) > 0)::numeric / NULLIF(COUNT(*), 0)::numeric) * 100, 1), 0)::float8",
              lt.pnl,
              lt.pnl_percent
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

  @doc """
  The strategies that traded in the window or hold an open trade, by P&L,
  each named: the Journal's filters over its trade list.
  """
  @spec traded_strategies(window()) :: [map()]
  def traded_strategies(window) do
    rows =
      window
      |> strategy_performance()
      |> Enum.filter(&(&1.trades > 0 or &1.open_trades > 0))

    names = strategy_names(Enum.map(rows, & &1.strategy_id))
    Enum.map(rows, &Map.put(&1, :name, Map.get(names, &1.strategy_id, &1.instrument)))
  end

  @doc """
  The latest live trades, open and closed, newest first: one row each for the
  Journal's trade list, with the strategy's name and why it closed. Only
  `strategy_id`'s trades when one is given.
  """
  @spec recent_trades(pos_integer(), String.t() | nil) :: [map()]
  def recent_trades(limit \\ 30, strategy_id \\ nil) do
    trades =
      trades_query()
      |> for_strategy(strategy_id && Ecto.UUID.cast(strategy_id))
      |> order_by([t], desc: t.entry_time)
      |> limit(^limit)
      |> Repo.all()

    names = strategy_names(Enum.map(trades, & &1.live_strategy_id))

    Enum.map(trades, fn t ->
      Map.merge(t, %{
        strategy: Map.get(names, t.live_strategy_id, "—"),
        why_closed: TradeStory.exit_label(t)
      })
    end)
  end

  @doc """
  One live trade told in plain words (`Opus.Journal.TradeStory`), with its
  strategy's name and how many live trades the strategy has closed. `nil`
  for an unknown id.
  """
  @spec trade(String.t()) :: map() | nil
  def trade(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{} = t <- trades_query() |> where([t], t.id == type(^uuid, Ecto.UUID)) |> Repo.one() do
      strategy = t.live_strategy_id && Repo.get(LiveStrategy, t.live_strategy_id)

      Map.merge(t, %{
        strategy: strategy && Strategies.display_name(strategy),
        story: TradeStory.tell(t, %{parameters: strategy && strategy.parameters}),
        strategy_closed_trades: closed_count(t.live_strategy_id)
      })
    else
      _ -> nil
    end
  end

  defp for_strategy(query, {:ok, uuid}),
    do: where(query, [t], t.live_strategy_id == type(^uuid, Ecto.UUID))

  defp for_strategy(query, _all), do: query

  defp trades_query do
    from(t in "live_trades",
      select: %{
        id: type(t.id, Ecto.UUID),
        live_strategy_id: type(t.live_strategy_id, Ecto.UUID),
        instrument: t.instrument,
        direction: t.direction,
        units: t.units,
        status: t.status,
        entry_price: t.entry_price,
        exit_price: t.exit_price,
        entry_time: type(t.entry_time, :utc_datetime_usec),
        exit_time: type(t.exit_time, :utc_datetime_usec),
        stop_loss_price: t.stop_loss_price,
        pnl: t.pnl,
        pnl_percent: t.pnl_percent,
        entry_reason: t.entry_reason,
        exit_reason: t.exit_reason,
        indicators_at_entry: type(t.indicators_at_entry, :map),
        mfe_pct: t.mfe_pct,
        mae_pct: t.mae_pct,
        sizing_metadata: type(t.sizing_metadata, :map),
        expected_entry_price: t.expected_entry_price,
        entry_spread: t.entry_spread,
        expected_exit_price: t.expected_exit_price,
        exit_spread: t.exit_spread
      }
    )
  end

  defp strategy_names(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(s in LiveStrategy, where: s.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, Strategies.display_name(&1)})
  end

  defp closed_count(nil), do: 0

  defp closed_count(strategy_id),
    do:
      Repo.aggregate(
        from(t in LiveTrade, where: t.live_strategy_id == ^strategy_id and t.status == "closed"),
        :count
      )

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
