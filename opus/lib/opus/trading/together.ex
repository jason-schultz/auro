defmodule Opus.Trading.Together do
  @moduledoc """
  Strategies backtested together on one account (the engine's
  `POST /api/strategy/portfolio`), for the Together page:

  - `choices/0`: what can be combined: your strategies (live or switched
    off), and the tested plays that passed the walk-forward, one per
    strategy, each with where it stands (`:status`) and so its one next
    step towards live (`next_step/1`).
  - `promote/1` and `retest/1`: those next steps. Switching a strategy on
    stays on its own page: every switched-on strategy already trades as
    one team on the account.
  - `run/1`: the chosen plays replayed together over the history they all
    share, with the account safety rules as they're set now and without
    them, plus each play alone and how they move together.
  - `companions/2`: every other play paired with one, ranked by what the
    pair does for its Sharpe, so the page can suggest a companion. A play
    that moves with it adds little; one that moves on its own steadies the
    account.

  A play's key is `"live:<id>"` for a strategy or `"cfg:<id>"` for a
  pipeline-tested config.
  """

  import Opus.Utils.Time, only: [parse_iso8601!: 1]
  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Pipeline.{Coordinator, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  alias Opus.Trading.{
    AccountLimits,
    CircuitBreaker,
    LiveStrategy,
    Strategies,
    StrategyResults,
    StrategyWords
  }

  @type status ::
          :trading
          | :switched_off
          | :ready
          | :old
          | {:testing, atom()}
          | {:stuck, atom()}
          | {:failed, atom(), map()}

  @type play :: %{
          key: String.t(),
          name: String.t(),
          instrument: String.t(),
          granularity: String.t(),
          timeframe: String.t(),
          enabled: boolean(),
          exempt: boolean(),
          status: status(),
          old: boolean(),
          holdout_seen: boolean(),
          variant: String.t() | nil,
          live_id: Ecto.UUID.t() | nil,
          config_id: Ecto.UUID.t() | nil,
          parameters: map()
        }

  @stages [:backtest, :walk_forward, :monte_carlo, :parameter_stability, :holdout]

  @doc """
  Your strategies and the tested plays, each list sorted for picking.

  A tested play is one strategy (`Strategies.trade_settings/1` on one instrument
  and timeframe) that passed a walk-forward at least once, shown once: its
  newest run by today's rules, or its newest old run when it has none. A
  strategy you already have is left out of `tested`. Plays that share a
  name, instrument and timeframe carry `variant`: the settings that tell
  them apart, in words (e.g. "ma period 25"); nil otherwise.
  """
  @spec choices() :: %{yours: [play()], tested: [play()]}
  def choices do
    # Only assignments of a recipe run in the engine.
    yours =
      LiveStrategy
      |> where([s], not is_nil(s.strategy_id))
      |> order_by([s], desc: s.enabled, asc: s.instrument, asc: s.granularity)
      |> Repo.all()
      |> Enum.map(&live_play/1)

    taken = MapSet.new(yours, &same/1)

    tested =
      tested_runs()
      |> Enum.group_by(&same/1)
      |> Enum.reject(fn {same, runs} ->
        MapSet.member?(taken, same) or not Enum.any?(runs, & &1.passed_walk_forward)
      end)
      |> Enum.map(fn {_same, runs} ->
        runs
        |> Enum.max_by(&{&1.status != :old, DateTime.to_unix(&1.inserted_at, :microsecond)})
        |> tested_play()
        |> Map.put(:holdout_seen, Enum.any?(runs, & &1.holdout_seen))
      end)
      |> Enum.sort_by(&{&1.instrument, &1.granularity, &1.name})

    variants = variants(yours ++ tested)
    with_variant = &Map.put(&1, :variant, variants[&1.key])

    %{yours: Enum.map(yours, with_variant), tested: Enum.map(tested, with_variant)}
  end

  # For plays that look alike (same name, instrument and timeframe), the
  # settings that differ between them, by play key.
  defp variants(plays) do
    plays
    |> Enum.group_by(&{&1.name, &1.instrument, &1.granularity})
    |> Enum.flat_map(fn
      {_alike, [_one]} ->
        []

      {_alike, group} ->
        flat = Map.new(group, &{&1.key, flatten(Strategies.trade_settings(&1.parameters))})
        paths = flat |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

        differ =
          Enum.filter(paths, fn path ->
            flat |> Map.values() |> Enum.uniq_by(& &1[path]) |> length() > 1
          end)

        Enum.map(group, fn play ->
          {play.key,
           Enum.map_join(differ, ", ", &"#{setting_words(&1)} #{value_words(flat[play.key][&1])}")}
        end)
    end)
    |> Map.new()
  end

  defp flatten(%{} = map, prefix \\ []) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case value do
        %{} = inner -> Map.merge(acc, flatten(inner, prefix ++ [key]))
        _leaf -> Map.put(acc, prefix ++ [key], value)
      end
    end)
  end

  # ["components", "ma", "params", "period"] -> "ma period".
  defp setting_words(path),
    do: path |> Enum.reject(&(&1 in ~w(components params))) |> Enum.join(" ")

  defp value_words(nil), do: "none"
  defp value_words(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp value_words(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp value_words(value), do: Jason.encode!(value)

  # Every run that passed a walk-forward, and every run by today's rules
  # (not archived) on the same instruments: a re-test is shown even before
  # it reaches the walk-forward, or when it fails before it.
  defp tested_runs do
    base =
      from(c in StrategyConfig,
        as: :config,
        # A basket is several markets in one test, not a play on one.
        where: not fragment("jsonb_exists(?, 'basket')", c.parameters),
        select: %{
          id: c.id,
          instrument: c.instrument,
          granularity: c.granularity,
          strategy_type: c.strategy_type,
          parameters: c.parameters,
          inserted_at: c.inserted_at,
          archived: not is_nil(c.archived_at)
        }
      )

    passed =
      base
      |> where(
        exists(
          from(e in StrategyEvaluation,
            where:
              e.strategy_config_id == parent_as(:config).id and e.stage == "walk_forward" and
                e.status == "passed"
          )
        )
      )
      |> Repo.all()

    passed_ids = MapSet.new(passed, & &1.id)
    instruments = passed |> Enum.map(& &1.instrument) |> Enum.uniq()

    current =
      base
      |> where([c], is_nil(c.archived_at) and c.instrument in ^instruments)
      |> Repo.all()

    runs = Enum.uniq_by(passed ++ current, & &1.id)
    stages = StrategyResults.for_configs(Enum.map(runs, &{&1.id, &1.inserted_at}))

    Enum.map(runs, fn run ->
      Map.merge(run, %{
        passed_walk_forward: MapSet.member?(passed_ids, run.id),
        status: run_status(stages[run.id], run.archived),
        # Any run of it judged on the sealed holdout window already.
        holdout_seen: stages[run.id].holdout.status in [:passed, :failed, :old_pass, :old_fail]
      })
    end)
  end

  @doc """
  Where one pipeline run stands (stages as `StrategyResults` shapes them):

  - `:old`: tested before the current rules. That is a run archived as
    tried before the block builder; or one with a stage result judged by
    earlier rules, passed or failed (`old`: its rules version is below
    today's or missing, `Opus.Pipeline.StrategyEvaluation.current?/1`); or
    a finished run that never got a stage the pipeline has now
    (`:not_run`: it ran before that stage joined).
  - `{:failed, stage, stage_result}`: failed `stage` by today's rules.
  - `{:stuck, stage}`: `stage` looks unfinished but nothing
    is running it (`Opus.Pipeline.Stuck`); it can be resumed from there.
  - `{:testing, stage}`: `stage` is running or waiting to run.
  - `:ready`: passed every stage, the holdout too.
  """
  @spec run_status(map(), boolean()) ::
          :old | :ready | {:testing, atom()} | {:stuck, atom()} | {:failed, atom(), map()}
  def run_status(stages, archived) do
    statuses = Enum.map(@stages, &{&1, stages[&1]})

    cond do
      archived or Enum.any?(statuses, fn {_stage, s} -> Map.get(s, :old, false) end) ->
        :old

      failed = Enum.find(statuses, fn {_stage, s} -> s.status == :failed end) ->
        {stage, result} = failed
        {:failed, stage, result}

      stuck = Enum.find(statuses, fn {_stage, s} -> s.status == :stuck end) ->
        {:stuck, elem(stuck, 0)}

      testing = Enum.find(statuses, fn {_stage, s} -> s.status in [:pending, :running] end) ->
        {:testing, elem(testing, 0)}

      stages.holdout.status == :passed and
          not Enum.any?(statuses, fn {_stage, s} -> s.status == :not_run end) ->
        :ready

      true ->
        :old
    end
  end

  @doc """
  The one next step a play offers, if any:

  - `:open`: it's on your account switched off; switch it on on its page;
  - `:promote`: it passed every test; add it to live, switched off;
  - `:retest`: tested before the current rules; send it through again.
  - `:resume`: stopped part-way with nothing running it; pick it up at the
    stuck stage (`Opus.Pipeline.Stuck.resume/3`).

  Nothing for a strategy trading now, one still testing, or one that failed
  by today's rules (testing it again is another try at luck).
  """
  @spec next_step(play()) :: :open | :promote | :retest | :resume | nil
  def next_step(%{status: :switched_off}), do: :open
  def next_step(%{status: :ready}), do: :promote
  def next_step(%{status: :old}), do: :retest
  def next_step(%{status: {:stuck, _stage}}), do: :resume
  def next_step(_play), do: nil

  @doc """
  Add a tested play that passed every test to live, switched off
  (`Coordinator.promote_to_live/1`). Switching it on stays on its page.
  """
  @spec promote(String.t()) ::
          {:ok, :promoted | :already_promoted} | {:error, :not_ready | term()}
  def promote(key) do
    case find(key) do
      %{config_id: id} = play when is_binary(id) ->
        if next_step(play) == :promote,
          do: Coordinator.promote_to_live(id),
          else: {:error, :not_ready}

      _other ->
        {:error, :not_ready}
    end
  end

  @doc """
  Send a play tested before the current rules through every test again, as
  a new config (`Coordinator.submit_config/1`) with the same strategy; the
  old run stays as history. It counts as one more try in the luck check.
  """
  @spec retest(String.t()) :: {:ok, StrategyConfig.t()} | {:error, :not_old | term()}
  def retest(key) do
    with %{config_id: id} = play when is_binary(id) <- find(key),
         :retest <- next_step(play),
         %StrategyConfig{} = config <- Repo.get(StrategyConfig, id) do
      Coordinator.submit_config(%{
        instrument: config.instrument,
        granularity: config.granularity,
        strategy_type: config.strategy_type,
        parameters: config.parameters
      })
    else
      _other -> {:error, :not_old}
    end
  end

  defp find(key) do
    %{yours: yours, tested: tested} = choices()
    Enum.find(yours ++ tested, &(&1.key == key))
  end

  defp live_play(s) do
    %{
      key: "live:#{s.id}",
      name: Strategies.display_name(s),
      instrument: s.instrument,
      granularity: s.granularity,
      timeframe: StrategyWords.timeframe(s.granularity),
      enabled: s.enabled,
      exempt: s.circuit_breaker_exempt,
      status: if(s.enabled, do: :trading, else: :switched_off),
      old: false,
      holdout_seen: false,
      live_id: s.id,
      config_id: nil,
      parameters: Strategies.engine_parameters(s)
    }
  end

  defp tested_play(run) do
    %{
      key: "cfg:#{run.id}",
      name: run.parameters["strategy_name"] || "Tested play",
      instrument: run.instrument,
      granularity: run.granularity,
      timeframe: StrategyWords.timeframe(run.granularity),
      enabled: false,
      exempt: false,
      status: run.status,
      old: run.status == :old,
      holdout_seen: false,
      live_id: nil,
      config_id: run.id,
      parameters: run.parameters
    }
  end

  @doc "Whether two plays are the same strategy: the same settings on the same instrument and timeframe."
  @spec same?(play(), play()) :: boolean()
  def same?(a, b), do: same(a) == same(b)

  defp same(play),
    do: {play.instrument, play.granularity, Strategies.trade_settings(play.parameters)}

  @doc """
  The plays with `keys` replayed together. `{:ok, result}` with:

  - `:with_rules` and `:without_rules`: the account's summary (yearly
    return, worst drop, Sharpe, trades taken and blocked, when the drawdown
    pause and circuit breaker would have tripped) and its chart points. The
    engine values the account at every bar, open trades at their market's
    latest close, so the worst drop, the chart and the drawdown pause
    include dips that recovered before a trade closed;
  - `:plays`: each play alone over the same years;
  - `:pairs`: how each two plays moved together, most alike first;
  - `:failed`: plays the engine couldn't test, and why.
  """
  @spec run([String.t()]) :: {:ok, map()} | {:error, term()}
  def run(keys) do
    plays = pick(keys)

    with {:ok, body} <- Client.portfolio(Enum.map(plays, &request/1), limits(plays)) do
      {:ok, shape(body, plays)}
    end
  end

  @doc """
  Every other play next to `base_key`, best partner first: each row with
  the pair's Sharpe and worst drop against the base alone, the other play's
  own numbers, and how the two move together. Plays tested before the
  current rules are left out unless `with_old`.
  """
  @spec companions(String.t(), boolean()) :: {:ok, [map()]} | {:error, term()}
  def companions(base_key, with_old \\ false) do
    %{yours: yours, tested: tested} = choices()
    plays = yours ++ tested
    base = Enum.find(plays, &(&1.key == base_key))
    others = Enum.reject(plays, &(&1.key == base_key or (&1.old and not with_old)))

    with %{} <- base,
         {:ok, %{"pairs" => rows}} <-
           Client.portfolio(Enum.map([base | others], &request/1), limits(plays), base_key) do
      by_key = Map.new(others, &{&1.key, &1})

      {:ok,
       rows
       |> Enum.map(&companion(&1, by_key))
       |> Enum.sort_by(&(-&1.sharpe_gain))}
    else
      nil -> {:error, :unknown_play}
      other -> other
    end
  end

  defp pick(keys) do
    %{yours: yours, tested: tested} = choices()
    wanted = MapSet.new(keys)
    Enum.filter(yours ++ tested, &MapSet.member?(wanted, &1.key))
  end

  defp request(play),
    do: %{key: play.key, parameters: play.parameters, breaker_exempt: play.exempt}

  # The account limits as set now, in the engine's units, with every play's
  # instrument group. Nil before the limits exist: the replay runs without.
  defp limits(plays) do
    case AccountLimits.get() do
      nil ->
        nil

      l ->
        %{
          risk_budget: l.risk_budget_pct / 100,
          max_open_per_group: l.max_open_per_group,
          groups: AccountLimits.groups(Enum.map(plays, & &1.instrument)),
          drawdown_pause: l.drawdown_pause_pct / 100,
          breaker: %{
            losses: l.breaker_losses,
            drawdown: l.breaker_drawdown_pct / 100,
            window_days: l.breaker_window_days,
            min_trades: CircuitBreaker.min_trades()
          }
        }
    end
  end

  defp shape(body, plays) do
    by_key = Map.new(plays, &{&1.key, &1})
    tested = body["plays"]
    names = Map.new(tested, &{&1["key"], label(by_key[&1["key"]])})

    %{
      from: parse_iso8601!(body["from"]),
      to: parse_iso8601!(body["to"]),
      with_rules: body["with_rules"] && outcome(body["with_rules"], names),
      without_rules: outcome(body["without_rules"], names),
      plays:
        Enum.map(tested, fn p ->
          Map.merge(by_key[p["key"]], %{alone: outcome(p["alone"], names)})
        end),
      pairs: pairs(tested, body["correlations"], names),
      failed: Enum.map(body["failed"], &%{name: label(by_key[&1["key"]]), error: &1["error"]})
    }
  end

  defp outcome(o, names) do
    %{
      total_return: o["total_return"],
      annual_return: o["annual_return"],
      max_drawdown: o["max_drawdown"],
      annual_sharpe: o["annual_sharpe"],
      taken: o["taken"],
      taken_by_play: o["taken_by_play"],
      blocked: %{
        risk_budget: o["blocked"]["risk_budget"],
        group_cap: o["blocked"]["group_cap"]
      },
      pause_trips: Enum.map(o["pause_trips"], &parse_iso8601!/1),
      breaker_trips:
        Enum.map(o["breaker_trips"], &%{name: names[&1["key"]], at: parse_iso8601!(&1["at"])}),
      points:
        Enum.map(
          o["points"],
          &%{time: parse_iso8601!(&1["time"]), equity: &1["equity"], drawdown: &1["drawdown"]}
        )
    }
  end

  # Each two plays once, with how alike their daily results were.
  defp pairs(tested, matrix, names) do
    keys = Enum.map(tested, & &1["key"])

    for {a, i} <- Enum.with_index(keys),
        {b, j} <- Enum.with_index(keys),
        i < j,
        c = matrix |> Enum.at(i) |> Enum.at(j),
        is_number(c) do
      %{a: names[a], b: names[b], correlation: c}
    end
    |> Enum.sort_by(&(-&1.correlation))
  end

  defp companion(row, by_key) do
    pair = row["pair"]
    base = row["base_alone"]

    %{
      play: by_key[row["key"]],
      correlation: row["correlation"],
      from: parse_iso8601!(row["from"]),
      to: parse_iso8601!(row["to"]),
      alone_sharpe: row["alone"]["annual_sharpe"],
      base_sharpe: base["annual_sharpe"],
      pair_sharpe: pair["annual_sharpe"],
      sharpe_gain: pair["annual_sharpe"] - base["annual_sharpe"],
      base_drawdown: base["max_drawdown"],
      pair_drawdown: pair["max_drawdown"],
      pair_return: pair["annual_return"],
      base_return: base["annual_return"]
    }
  end

  @doc "A play's name with where it runs, as lists show it."
  @spec label(play() | nil) :: String.t()
  def label(nil), do: "A play"
  def label(play), do: "#{play.name} · #{play.instrument} #{play.granularity}"

  @doc "How alike two plays' daily results are, in words."
  @spec alike_words(float() | nil) :: String.t()
  def alike_words(nil), do: "not enough shared days to tell"
  def alike_words(c) when c >= 0.5, do: "move together"
  def alike_words(c) when c >= 0.2, do: "loosely together"
  def alike_words(c) when c > -0.2, do: "independent"
  def alike_words(_c), do: "tend to move opposite"
end
