defmodule Opus.Trading.Together do
  @moduledoc """
  Strategies backtested together on one account (the engine's
  `POST /api/strategy/portfolio`), for the Together page:

  - `choices/0`: what can be combined: your strategies (live or switched
    off), and the tested plays that passed the walk-forward.
  - `run/1`: the chosen plays replayed together over the history they all
    share, with the account safety rules as they're set now and without
    them, plus each play alone and how they move together.
  - `companions/1`: every other play paired with one, ranked by what the
    pair does for its Sharpe, so the page can suggest a companion. A play
    that moves with it adds little; one that moves on its own steadies the
    account.

  A play's key is `"live:<id>"` for a strategy or `"cfg:<id>"` for a
  pipeline-tested config.
  """

  import Opus.Utils.Time, only: [parse_iso8601!: 1]
  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation}
  alias Opus.Repo
  alias Opus.Trading.{AccountLimits, CircuitBreaker, LiveStrategy, Strategies, StrategyWords}

  @type play :: %{
          key: String.t(),
          name: String.t(),
          instrument: String.t(),
          granularity: String.t(),
          timeframe: String.t(),
          enabled: boolean(),
          exempt: boolean(),
          older_rules: boolean(),
          parameters: map()
        }

  @doc "Your strategies and the tested plays, each list sorted for picking."
  @spec choices() :: %{yours: [play()], tested: [play()]}
  def choices do
    # Only assignments of a recipe run in the engine.
    yours =
      LiveStrategy
      |> where([s], not is_nil(s.strategy_id))
      |> order_by([s], desc: s.enabled, asc: s.instrument, asc: s.granularity)
      |> Repo.all()
      |> Enum.map(&live_play/1)

    taken = MapSet.new(yours, &recipe_of(&1.parameters))

    tested =
      from(c in StrategyConfig,
        join: e in StrategyEvaluation,
        on: e.strategy_config_id == c.id,
        where: e.stage == "walk_forward" and e.status == "passed",
        order_by: [desc: c.inserted_at],
        # A pass from before Oct 28 recorded no checks: older, looser rules.
        select: {c, not fragment("jsonb_exists(?, 'checks')", e.stats)}
      )
      |> Repo.all()
      |> Enum.uniq_by(&recipe_of(elem(&1, 0).parameters))
      |> Enum.reject(&MapSet.member?(taken, recipe_of(elem(&1, 0).parameters)))
      |> Enum.map(fn {c, older_rules} -> tested_play(c, older_rules) end)
      |> Enum.sort_by(&{&1.instrument, &1.granularity, &1.name})

    %{yours: yours, tested: tested}
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
      older_rules: false,
      parameters: Strategies.engine_parameters(s)
    }
  end

  defp tested_play(c, older_rules) do
    %{
      key: "cfg:#{c.id}",
      name: c.parameters["strategy_name"] || "Tested play",
      instrument: c.instrument,
      granularity: c.granularity,
      timeframe: StrategyWords.timeframe(c.granularity),
      enabled: false,
      exempt: false,
      older_rules: older_rules,
      parameters: c.parameters
    }
  end

  # A strategy's rules without its sizing: two plays with the same rules on
  # the same instrument are the same play.
  defp recipe_of(parameters), do: Map.delete(parameters, "sizing")

  @doc """
  The plays with `keys` replayed together. `{:ok, result}` with:

  - `:with_rules` and `:without_rules`: the account's summary (yearly
    return, worst drop, Sharpe, trades taken and blocked, when the drawdown
    pause and circuit breaker would have tripped) and its chart points;
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
  own numbers, and how the two move together.
  """
  @spec companions(String.t()) :: {:ok, [map()]} | {:error, term()}
  def companions(base_key) do
    %{yours: yours, tested: tested} = choices()
    plays = yours ++ tested
    base = Enum.find(plays, &(&1.key == base_key))
    others = Enum.reject(plays, &(&1.key == base_key))

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
