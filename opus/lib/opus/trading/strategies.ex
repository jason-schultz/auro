defmodule Opus.Trading.Strategies do
  @moduledoc """
  The live strategies pages: every deployed strategy with what Opus knows
  about it (the rules engine's verdict and regime inputs, an open circuit
  breaker suspension, open trades, the last signal) and, for one strategy,
  its trades, its signal log, the candles behind its chart and, when the
  engine is reachable, the statistics and indicator scalars Rust computes.

  Opus owns the rows and the decisions; Rust owns the enable/disable switch
  because flipping it loads or unloads candle buffers, and it owns deletion
  for the same reason.
  """

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Repo

  alias Opus.Trading.{
    Fragility,
    LiveStrategy,
    Recipe,
    Rule,
    RulesEngine,
    SignalChart,
    StrategyResults,
    StrategyWords,
    Suspension
  }

  @type row :: %{
          id: String.t(),
          name: String.t(),
          strategy_type: String.t(),
          instrument: String.t(),
          granularity: String.t(),
          enabled: boolean(),
          circuit_breaker_exempt: boolean(),
          created_at: DateTime.t(),
          rule: map() | nil,
          suspension: map() | nil,
          open_trades: non_neg_integer(),
          last_signal: map() | nil
        }

  # Sizing a preview or a test uses when none is set yet: the engine needs one
  # to read the strategy, and 1% is what the running strategies use.
  @default_sizing %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}

  @doc "The sizing a new assignment or a test run starts with."
  @spec default_sizing() :: map()
  def default_sizing, do: @default_sizing

  # Bars the detail chart shows, by how fast the timeframe moves.
  @chart_bars %{"M1" => 90, "M5" => 90, "M15" => 80, "H1" => 80, "H4" => 80, "D" => 120}

  @doc "Every deployed strategy, enabled first, then by instrument and timeframe."
  @spec list() :: [row()]
  def list do
    strategies =
      LiveStrategy
      |> order_by([s], desc: s.enabled, asc: s.instrument, asc: s.granularity)
      |> Repo.all()

    ids = Enum.map(strategies, & &1.id)
    context = context(ids)
    Enum.map(strategies, &row(&1, context))
  end

  @doc """
  Every recipe with the instruments it's assigned to, for the Strategies
  page: the rules in plain words, each assignment's status row (as
  `list/0`), sizing and test results, and why the recipe is locked.

  A recipe is locked while any of its assignments is switched on or holds
  an open trade: changing its rules would change a strategy mid-trade.
  `locked_by` names those assignments; empty means it's free to edit.
  `status` is `:trading` (locked), `:off` (assigned, nothing running) or
  `:draft` (not assigned anywhere yet). `runs` are its test runs on
  instruments it isn't assigned to yet. Trading first, drafts last.
  """
  @spec recipes() :: [map()]
  def recipes do
    assignments =
      LiveStrategy
      |> order_by([s], desc: s.enabled, asc: s.instrument)
      |> Repo.all()

    ids = Enum.map(assignments, & &1.id)
    context = context(ids)
    results = StrategyResults.for_ids(ids)
    by_recipe = Enum.group_by(assignments, & &1.strategy_id)

    Recipe
    |> Repo.all()
    |> Enum.map(fn recipe ->
      rows =
        by_recipe
        |> Map.get(recipe.id, [])
        |> Enum.map(fn strategy ->
          strategy
          |> row(context)
          |> Map.merge(%{
            sizing: StrategyWords.sizing(strategy.sizing),
            sizing_params: strategy.sizing,
            results: Map.fetch!(results, strategy.id)
          })
        end)

      locked_by = Enum.filter(rows, &(&1.enabled or &1.open_trades > 0))
      assigned = MapSet.new(rows, & &1.instrument)

      recipe
      |> recipe_view()
      |> Map.merge(%{
        assignments: rows,
        locked_by: locked_by,
        # Test runs on instruments it isn't on yet: a draft's, or a copy's.
        runs:
          recipe.definition
          |> StrategyResults.for_recipe()
          |> Enum.reject(&MapSet.member?(assigned, &1.instrument)),
        status:
          cond do
            locked_by != [] -> :trading
            rows == [] -> :draft
            true -> :off
          end
      })
    end)
    |> Enum.sort_by(&{status_rank(&1.status), &1.name})
  end

  defp status_rank(:trading), do: 0
  defp status_rank(:off), do: 1
  defp status_rank(:draft), do: 2

  @doc "A recipe's own fields with its rules in plain words."
  @spec recipe_view(Recipe.t()) :: map()
  def recipe_view(%Recipe{} = recipe) do
    %{
      id: recipe.id,
      name: recipe.name,
      granularity: recipe.granularity,
      timeframe: StrategyWords.timeframe(recipe.granularity),
      notes: recipe.notes,
      definition: recipe.definition,
      created_at: recipe.created_at,
      rules: StrategyWords.rules(recipe.definition, recipe.granularity)
    }
  end

  @doc """
  The full strategy JSON the engine reads: the recipe plus the
  instrument, timeframe and sizing. The same shape the database bridge
  builds for an assignment (`PARAMETERS_SQL` in Rust).
  """
  @spec compose(map(), String.t(), String.t(), map() | nil) :: map()
  def compose(definition, instrument, granularity, sizing) do
    definition
    |> Map.merge(%{"instrument" => instrument, "granularity" => granularity})
    |> then(&if(sizing, do: Map.put(&1, "sizing", sizing), else: &1))
  end

  @doc """
  An assignment's full strategy JSON as the engine runs it: its recipe with
  its instrument, the recipe's timeframe and its sizing (`compose/4`).
  """
  @spec engine_parameters(LiveStrategy.t()) :: map()
  def engine_parameters(%LiveStrategy{} = strategy) do
    %{recipe: recipe} = strategy = Repo.preload(strategy, :recipe)
    compose(recipe.definition, strategy.instrument, recipe.granularity, strategy.sizing)
  end

  @doc """
  Where the recipe would have bought and sold over the last `count` bars of
  `instrument`, shaped for a chart (`Opus.Trading.SignalChart`). Needs the
  engine, which also checks the rules: a recipe it can't read comes back
  as `{:error, reason}`.
  """
  @spec preview(map(), String.t(), String.t(), map() | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def preview(definition, instrument, granularity, sizing, count \\ 120) do
    params = compose(definition, instrument, granularity, sizing || @default_sizing)

    with {:ok, body} <- Client.signal_preview(params, count) do
      {:ok, SignalChart.shape(body, definition, granularity)}
    end
  end

  @doc """
  How the strategy did over its whole test history against just holding the
  instrument (`Opus.Auro.Client.strategy_report/1`): `%{points, summary}`
  with each point `%{time, strategy, hold, drawdown}` (shares of one) and
  the summary's returns, worst drops, time in the market and trade count.
  `{:ok, nil}` when there's no history to test on.
  """
  @spec report(map(), String.t(), String.t(), map() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def report(definition, instrument, granularity, sizing) do
    params = compose(definition, instrument, granularity, sizing || @default_sizing)

    with {:ok, %{"report" => report}} <- Client.strategy_report(params) do
      {:ok, report && report_view(report)}
    end
  end

  defp report_view(%{"points" => points, "summary" => s}) do
    %{
      points:
        Enum.map(points, fn p ->
          %{
            time: at(p["time"]),
            strategy: p["strategy"],
            hold: p["hold"],
            drawdown: p["drawdown"]
          }
        end),
      summary: %{
        strategy_return: s["strategy_return"],
        hold_return: s["hold_return"],
        strategy_max_drawdown: s["strategy_max_drawdown"],
        hold_max_drawdown: s["hold_max_drawdown"],
        time_in_market: s["time_in_market"],
        num_trades: s["num_trades"],
        from: at(s["from"]),
        to: at(s["to"])
      }
    }
  end

  defp at(text) do
    {:ok, at, _} = DateTime.from_iso8601(text)
    at
  end

  @doc """
  Re-run the strategy at settings near its own on two of its settings (or
  one), judged by the backtest standard: the "Is it fragile?" grid, shaped by
  `Opus.Trading.Fragility.shape/3`.
  """
  @spec fragility(map(), String.t(), String.t(), map() | nil, map(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def fragility(definition, instrument, granularity, sizing, x, y) do
    params = compose(definition, instrument, granularity, sizing || @default_sizing)
    axis = fn a -> a && %{component: a.component, param: a.param, values: Fragility.values(a)} end

    with {:ok, %{"cells" => cells}} <- Client.strategy_sensitivity(params, axis.(x), axis.(y)) do
      {:ok, Fragility.shape(cells, x, y)}
    end
  end

  @doc "Instruments with bars at `granularity` in the last 30 days: what a preview can run on."
  @spec preview_instruments(String.t()) :: [String.t()]
  def preview_instruments(granularity) do
    since = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    # One index probe per instrument (candles' key is instrument_id,
    # granularity, timestamp); a DISTINCT over the candles takes seconds.
    named =
      from(c in "candles",
        where:
          c.instrument_id == parent_as(:instrument).id and c.granularity == ^granularity and
            c.timestamp >= ^since,
        limit: 1,
        select: c.instrument
      )

    from(i in "instruments",
      as: :instrument,
      inner_lateral_join: c in subquery(named),
      on: true,
      order_by: c.instrument,
      select: c.instrument
    )
    |> Repo.all()
  end

  @doc """
  One strategy with everything its page shows. The engine-backed parts
  (`stats`, `indicators`) are `nil` when Rust is unreachable, and
  `engine_error` says why.
  """
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %LiveStrategy{} = strategy <- Repo.get(LiveStrategy, uuid) do
      {:ok, detail(strategy)}
    else
      _ -> :error
    end
  end

  defp detail(strategy) do
    strategy = Repo.preload(strategy, :recipe)
    siblings = siblings(strategy)
    row = row(strategy, context([strategy.id]))
    {stats, engine_error} = engine_stats(strategy.id)
    overlay_period = ma_overlay_period(strategy.parameters)
    bars = Map.get(@chart_bars, strategy.granularity, 80)
    candles = candles(strategy.instrument, strategy.granularity, bars + (overlay_period || 0))

    Map.merge(row, %{
      parameters: strategy.parameters || %{},
      logic: logic(strategy.parameters || %{}),
      open_trade: open_trade(strategy.id),
      trades: trades(strategy.id),
      signals: signals(strategy.id),
      stats: stats,
      indicators: indicators(strategy),
      engine_error: engine_error,
      candles: candles,
      chart_bars: bars,
      overlay_period: overlay_period,
      recipe: recipe_view(strategy.recipe),
      sizing: StrategyWords.sizing(strategy.sizing),
      sizing_params: strategy.sizing,
      siblings: siblings,
      # Tests on instruments the recipe doesn't run on.
      runs:
        strategy.recipe.definition
        |> StrategyResults.for_recipe()
        |> Enum.reject(fn run -> Enum.any?(siblings, &(&1.instrument == run.instrument)) end),
      locked_by: Enum.filter(siblings, &(&1.enabled or &1.open_trades > 0)),
      results: StrategyResults.for_ids([strategy.id]) |> Map.fetch!(strategy.id)
    })
  end

  # Every instrument the same recipe runs on, this one included.
  defp siblings(strategy) do
    members =
      LiveStrategy
      |> where([s], s.strategy_id == ^strategy.strategy_id)
      |> order_by([s], desc: s.enabled, asc: s.instrument)
      |> Repo.all()

    open = members |> Enum.map(& &1.id) |> open_trades_by_strategy()

    Enum.map(members, fn s ->
      %{
        id: s.id,
        instrument: s.instrument,
        enabled: s.enabled,
        open_trades: Map.get(open, s.id, 0),
        sizing: StrategyWords.sizing(s.sizing)
      }
    end)
  end

  @doc """
  The statistics Rust aggregates per strategy (backtest, out-of-sample,
  k-fold, live), keyed by strategy id. `{:error, reason}` when the engine
  is unreachable; the pages then show the rows without them.
  """
  @spec stats() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def stats do
    with {:ok, %{"strategies" => strategies}} <- Client.list_live_strategies() do
      {:ok, Map.new(strategies, &{&1["id"], stat(&1)})}
    end
  end

  defp stat(s) do
    %{
      source: s["source"],
      backtest: s["backtest_stats"],
      oos: s["oos_stats"],
      kfold: s["kfold_stats"],
      live: s["live_stats"]
    }
  end

  defp engine_stats(id) do
    case stats() do
      {:ok, by_id} -> {Map.get(by_id, id), nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp indicators(strategy) do
    case Client.get_indicators(strategy.instrument, strategy.granularity) do
      {:ok, body} -> body
      {:error, _} -> nil
    end
  end

  @doc "Flip a strategy's enabled switch in Rust (which loads or unloads its buffers)."
  @spec toggle(String.t()) :: {:ok, map()} | {:error, term()}
  def toggle(id) when is_binary(id), do: Client.toggle_live_strategy(id)

  @doc "Delete a strategy through Rust, which refuses while it has open trades."
  @spec delete(String.t()) :: {:ok, map()} | {:error, term()}
  def delete(id) when is_binary(id), do: Client.delete_live_strategy(id)

  @doc """
  Clear a strategy's open circuit-breaker suspensions by hand and have the
  rules engine recompute. Suspensions never clear on a timer.
  """
  @spec reset_suspension(String.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_id | :none_open}
  def reset_suspension(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid |> clear_open_suspensions() |> recompute_if_cleared()
      :error -> {:error, :invalid_id}
    end
  end

  defp clear_open_suspensions(uuid) do
    now = DateTime.utc_now()

    from(s in Suspension, where: s.live_strategy_id == ^uuid and is_nil(s.cleared_at))
    |> Repo.update_all(set: [cleared_at: now, cleared_by: "manual", updated_at: now])
  end

  defp recompute_if_cleared({0, _}), do: {:error, :none_open}

  defp recompute_if_cleared({count, _}) do
    RulesEngine.recompute()
    {:ok, count}
  end

  @doc """
  The regime inputs a rule was decided on, as `{composite, frames}` where
  each frame is `%{frame, regime, adx}`. Rows read back from the database
  carry string keys.
  """
  @spec regime_summary(map() | nil) :: {String.t() | nil, [map()]}
  def regime_summary(nil), do: {nil, []}

  def regime_summary(inputs) when is_map(inputs) do
    frames =
      case fetch(inputs, :frames) do
        list when is_list(list) ->
          Enum.map(list, fn frame ->
            %{
              frame: fetch(frame, :frame),
              regime: frame |> fetch(:regime) |> regime_name(),
              adx: fetch(frame, :adx)
            }
          end)

        _ ->
          []
      end

    {inputs |> fetch(:composite) |> regime_name(), frames}
  end

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp fetch(_other, _key), do: nil

  defp regime_name(nil), do: nil
  defp regime_name(regime) when is_atom(regime), do: Atom.to_string(regime)
  defp regime_name(regime), do: regime

  @doc """
  A strategy's parameters as the page explains them: the named components
  with their settings, then one line per rule (entries, exits, stop,
  sizing, hold limit). Older single-component strategies have flat
  parameters; those come back as plain settings.
  """
  @spec logic(map()) :: %{
          components: [map()],
          rules: [{String.t(), String.t()}],
          settings: [{String.t(), String.t()}]
        }
  def logic(%{"components" => components} = params) when is_map(components) do
    %{
      components:
        Enum.map(components, fn {key, %{} = component} ->
          %{key: key, type: component["type"], params: settings(component["params"])}
        end),
      rules:
        Enum.reject(
          [
            {"Long when", expression(get_in(params, ["entry", "long"]))},
            {"Short when", expression(get_in(params, ["entry", "short"]))},
            {"Exit long", expression(get_in(params, ["exit", "long"]))},
            {"Exit short", expression(get_in(params, ["exit", "short"]))},
            {"Stop", typed(params["stop"])},
            {"Sizing", typed(params["sizing"])},
            {"Max hold", hold(params["max_hold_bars"])}
          ],
          fn {_, text} -> is_nil(text) end
        ),
      settings: []
    }
  end

  def logic(params) when is_map(params) do
    %{
      components: [],
      rules: [],
      settings:
        settings(
          Map.drop(params, [
            "strategy_name",
            "instrument",
            "granularity",
            "strategy_id",
            "version"
          ])
        )
    }
  end

  defp expression(nil), do: nil
  defp expression(port) when is_binary(port), do: port
  defp expression(%{"and" => parts}), do: Enum.map_join(parts, " and ", &expression/1)
  defp expression(%{"or" => parts}), do: Enum.map_join(parts, " or ", &expression/1)
  defp expression(%{"not" => part}), do: "not " <> expression(part)
  defp expression(other), do: inspect(other)

  defp typed(%{"type" => type} = spec) do
    case settings(spec["params"]) do
      [] -> type
      pairs -> "#{type} (" <> Enum.map_join(pairs, ", ", fn {k, v} -> "#{k} #{v}" end) <> ")"
    end
  end

  defp typed(_), do: nil

  defp hold(nil), do: "none"
  defp hold(bars), do: "#{bars} bars"

  defp settings(nil), do: []

  defp settings(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, value(v)} end)

  defp settings(_), do: []

  defp value(v) when is_binary(v), do: v
  defp value(v) when is_number(v), do: to_string(v)
  defp value(v), do: inspect(v)

  # An MaFilter component's period, so the chart can draw the average the
  # strategy filters on.
  defp ma_overlay_period(%{"components" => components}) when is_map(components) do
    Enum.find_value(components, fn
      {_, %{"type" => "MaFilter", "params" => %{"period" => period}}} when is_integer(period) ->
        period

      _ ->
        nil
    end)
  end

  defp ma_overlay_period(_), do: nil

  @doc """
  A strategy's display name: composites carry the name the pipeline gave
  them; the older single-component rows are named after their type.
  """
  @spec display_name(%LiveStrategy{}) :: String.t()
  def display_name(%LiveStrategy{parameters: %{"strategy_name" => name}})
      when is_binary(name) and name != "",
      do: name

  def display_name(%LiveStrategy{strategy_type: type}),
    do: type |> String.replace("_", " ") |> String.capitalize()

  defp row(strategy, context) do
    %{
      id: strategy.id,
      name: display_name(strategy),
      strategy_type: strategy.strategy_type,
      instrument: strategy.instrument,
      granularity: strategy.granularity,
      enabled: strategy.enabled,
      circuit_breaker_exempt: strategy.circuit_breaker_exempt,
      created_at: strategy.created_at,
      rule: Map.get(context.rules, strategy.id),
      suspension: Map.get(context.suspensions, strategy.id),
      open_trades: Map.get(context.open_trades, strategy.id, 0),
      last_signal: Map.get(context.signals, strategy.id)
    }
  end

  defp context(ids) do
    %{
      rules: rules_by_strategy(ids),
      suspensions: open_suspensions_by_strategy(ids),
      open_trades: open_trades_by_strategy(ids),
      signals: last_signal_by_strategy(ids)
    }
  end

  defp rules_by_strategy(ids) do
    from(r in Rule, where: r.live_strategy_id in ^ids)
    |> Repo.all()
    |> Map.new(fn rule ->
      {composite, frames} = regime_summary(rule.regime_inputs)

      {rule.live_strategy_id,
       %{
         enabled: rule.enabled,
         reason: rule.reason,
         computed_at: rule.computed_at,
         composite: composite,
         frames: frames
       }}
    end)
  end

  defp open_suspensions_by_strategy(ids) do
    Suspension.open_query()
    |> where([s], s.live_strategy_id in ^ids)
    |> Repo.all()
    |> Enum.reduce(%{}, fn s, acc ->
      Map.put_new(acc, s.live_strategy_id, %{
        trigger_kind: s.trigger_kind,
        trigger_detail: s.trigger_detail,
        triggered_at: s.triggered_at
      })
    end)
  end

  defp open_trades_by_strategy(ids) do
    from(t in "live_trades",
      where: t.status == "open" and t.live_strategy_id in type(^ids, {:array, Ecto.UUID}),
      group_by: t.live_strategy_id,
      select: {type(t.live_strategy_id, Ecto.UUID), count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp last_signal_by_strategy(ids) do
    from(e in "signal_events",
      where: e.strategy_id in type(^ids, {:array, Ecto.UUID}),
      distinct: e.strategy_id,
      order_by: [asc: e.strategy_id, desc: e.timestamp],
      select: %{
        strategy_id: type(e.strategy_id, Ecto.UUID),
        action: e.action,
        reason: e.reason,
        at: type(e.timestamp, :utc_datetime_usec)
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.strategy_id, Map.delete(&1, :strategy_id)})
  end

  defp open_trade(id) do
    trades_query(id)
    |> where([t], t.status == "open")
    |> limit(1)
    |> Repo.one()
  end

  defp trades(id), do: trades_query(id) |> limit(50) |> Repo.all()

  defp trades_query(id) do
    from(t in "live_trades",
      where: t.live_strategy_id == type(^id, Ecto.UUID),
      order_by: [desc: t.entry_time],
      select: %{
        id: type(t.id, Ecto.UUID),
        direction: t.direction,
        units: t.units,
        entry_price: t.entry_price,
        exit_price: t.exit_price,
        entry_time: type(t.entry_time, :utc_datetime_usec),
        exit_time: type(t.exit_time, :utc_datetime_usec),
        stop_loss_price: t.stop_loss_price,
        take_profit_price: t.take_profit_price,
        pnl: t.pnl,
        pnl_percent: t.pnl_percent,
        status: t.status,
        exit_reason: t.exit_reason
      }
    )
  end

  defp signals(id) do
    from(e in "signal_events",
      where: e.strategy_id == type(^id, Ecto.UUID),
      order_by: [desc: e.timestamp],
      limit: 20,
      select: %{
        action: e.action,
        reason: e.reason,
        price: e.price,
        at: type(e.timestamp, :utc_datetime_usec)
      }
    )
    |> Repo.all()
  end

  defp candles(instrument, granularity, count) do
    from(c in "candles",
      where: c.instrument == ^instrument and c.granularity == ^granularity and c.complete,
      order_by: [desc: c.timestamp],
      limit: ^count,
      select: %{
        time: type(c.timestamp, :utc_datetime_usec),
        open: c.open,
        high: c.high,
        low: c.low,
        close: c.close
      }
    )
    |> Repo.all()
    |> Enum.reverse()
  end
end
