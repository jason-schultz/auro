defmodule Opus.Trading.Baskets do
  @moduledoc """
  Testing one recipe on several markets at once (research/roadmap.md,
  "Portfolio backtests"). A basket is a thin wrapper: the recipe, a list of
  markets on its timeframe, and a mode.

  - `"separate"`: each market gets its own run through the tests, exactly
    as `Recipes.run_tests/2` does for one. Nothing new is stored.
  - `"together"`: one pipeline run on all of them as one account: every
    market trades the recipe's own rules, each trade sized the live way,
    and the stages judge the account's one curve.
  - `"ranked"`: one run where, every so many bars, the markets are ranked
    by a value one of the recipe's blocks shows (a rate gap, a past
    return); the best are bought, the worst sold, until the next
    rebalance. The recipe's buy and sell rules aren't used; its stop sets
    each position's size.

  A together or ranked basket is a `strategy_configs` row whose strategy
  JSON carries `"basket" => %{"markets", "mode", "rank"}`; its `instrument`
  is the first market (the column needs one). The engine reads the basket
  (`auro_be/src/engine/pipeline/basket.rs`). Baskets aren't promoted to
  live: `Coordinator.promote_to_live/1` refuses them.
  """

  import Ecto.Query

  alias Opus.Instruments
  alias Opus.Pipeline.Coordinator
  alias Opus.Repo
  alias Opus.Trading.{Blocks, Recipe, Recipes, Strategies}

  @max_markets 40
  @timeframes ~w(D H4)
  @modes ~w(separate together ranked)

  @presets [
    %{
      id: "metals_energy_indices",
      label: "Metals, energy and indices",
      classes: ~w(metal commodity index)
    },
    %{id: "indices", label: "Stock indices", classes: ~w(index)},
    %{id: "metals_energy", label: "Metals, energy and crops", classes: ~w(metal commodity)},
    %{id: "fx", label: "Currencies", classes: ~w(fx_major fx_cross)},
    %{id: "bonds", label: "Bonds", classes: ~w(bond)}
  ]

  @class_names %{
    "index" => "Stock indices",
    "metal" => "Metals",
    "commodity" => "Energy and crops",
    "fx_major" => "Major currencies",
    "fx_cross" => "Other currency pairs",
    "bond" => "Bonds"
  }

  @doc "Most markets one basket holds."
  @spec max_markets() :: pos_integer()
  def max_markets, do: @max_markets

  @doc "Whether a recipe's timeframe can be tested as a basket (daily or 4-hour)."
  @spec timeframe_ok?(String.t()) :: boolean()
  def timeframe_ok?(granularity), do: granularity in @timeframes

  @doc "Ready-made market groups: `%{id, label, classes}`."
  @spec presets() :: [map()]
  def presets, do: @presets

  @doc "A market class in words."
  @spec class_name(String.t()) :: String.t()
  def class_name(class), do: Map.get(@class_names, class, class)

  @doc """
  The OANDA markets a basket can hold at `granularity`: active, with bars
  from before the sealed holdout (what the tests run on). `%{symbol,
  asset_class}`, by class then symbol.
  """
  @spec markets(String.t()) :: [%{symbol: String.t(), asset_class: String.t()}]
  def markets(granularity) do
    before = DateTime.new!(Recipes.holdout_start(), ~T[00:00:00], "Etc/UTC")

    # One index probe per instrument, as `Strategies.preview_instruments/1`.
    probe =
      from(c in "candles",
        where:
          c.instrument_id == parent_as(:instrument).id and c.granularity == ^granularity and
            c.timestamp < ^before,
        limit: 1,
        select: c.instrument
      )

    from(i in "instruments",
      as: :instrument,
      inner_lateral_join: c in subquery(probe),
      on: true,
      where: i.active and i.exchange == "OANDA",
      order_by: [i.asset_class, c.instrument],
      select: %{symbol: c.instrument, asset_class: i.asset_class}
    )
    |> Repo.all()
  end

  @doc "The symbols of a preset among `markets`."
  @spec preset([map()], String.t()) :: [String.t()]
  def preset(markets, id) do
    classes = Enum.find_value(@presets, [], &(&1.id == id && &1.classes))
    for m <- markets, m.asset_class in classes, do: m.symbol
  end

  @doc """
  What a ranked basket can rank by: every value the recipe's blocks show,
  `{"<block>.<value>", "words"}`.
  """
  @spec rank_choices(map()) :: [{String.t(), String.t()}]
  def rank_choices(definition) do
    for {name, %{"type" => type}} <- Map.get(definition, "components", %{}),
        block = Blocks.get(type),
        block != nil,
        draw <- Map.get(block, :draw, []),
        do: {"#{name}.#{draw.key}", "#{block.name}: #{draw.label}"}
  end

  @doc "Bars between rebalances that make about a month on `granularity`."
  @spec monthly_bars(String.t()) :: pos_integer()
  def monthly_bars("H4"), do: 126
  def monthly_bars(_daily), do: 21

  @doc """
  Send the recipe through the tests on `markets`. `opts`:

    - `mode`: `"separate"`, `"together"` or `"ranked"`.
    - `rank`: for ranked, `%{"by", "every_bars", "long_top", "short_bottom"}`,
      plus `"buy" => "lowest"` to buy the lowest scores and sell the
      highest (short-term reversal); without it the highest are bought.

  Returns `{:ok, configs}` (one per market when separate, else one), or
  `{:error, words}` saying what to change.
  """
  @spec submit(Recipe.t(), [String.t()], map()) :: {:ok, [term()]} | {:error, String.t()}
  def submit(%Recipe{} = recipe, markets, opts) do
    markets = markets |> Enum.uniq() |> Enum.sort()
    mode = opts["mode"]

    with :ok <- check(recipe, markets, mode),
         {:ok, rank} <- rank(mode, opts["rank"], length(markets)) do
      case mode do
        "separate" -> separately(recipe, markets)
        _ -> together(recipe, markets, mode, rank)
      end
    end
  end

  defp check(recipe, markets, mode) do
    cond do
      mode not in @modes ->
        {:error, "Pick how to test them."}

      not timeframe_ok?(recipe.granularity) ->
        {:error, "Baskets are tested on daily or 4-hour bars only."}

      length(markets) < 2 ->
        {:error, "Pick at least 2 markets."}

      length(markets) > @max_markets ->
        {:error, "Pick at most #{@max_markets} markets; #{length(markets)} are picked."}

      true ->
        :ok
    end
  end

  defp rank("ranked", %{} = rank, count) do
    with {:ok, every} <- whole(rank["every_bars"], 1, "Bars between rebalances"),
         {:ok, top} <- whole(rank["long_top"], 0, "How many to buy"),
         {:ok, bottom} <- whole(rank["short_bottom"], 0, "How many to sell") do
      cond do
        not is_binary(rank["by"]) or not String.contains?(rank["by"], ".") ->
          {:error, "Pick what to rank the markets by."}

        top + bottom == 0 ->
          {:error, "The ranking must buy or sell at least one market."}

        top + bottom > count ->
          {:error, "It buys #{top} and sells #{bottom}: more than the #{count} markets picked."}

        true ->
          # Stored only when it's the reversal, so a default ranking stays
          # the same settings as one saved before the choice existed.
          {:ok,
           Map.merge(
             %{
               "by" => rank["by"],
               "every_bars" => every,
               "long_top" => top,
               "short_bottom" => bottom
             },
             if(rank["buy"] == "lowest", do: %{"buy" => "lowest"}, else: %{})
           )}
      end
    end
  end

  defp rank("ranked", _rank, _count), do: {:error, "Pick what to rank the markets by."}
  defp rank(_mode, _rank, _count), do: {:ok, nil}

  defp whole(value, min, label) do
    case value do
      n when is_integer(n) and n >= min ->
        {:ok, n}

      text when is_binary(text) ->
        case Integer.parse(String.trim(text)) do
          {n, ""} when n >= min -> {:ok, n}
          _ -> {:error, "#{label} must be a whole number of at least #{min}."}
        end

      _ ->
        {:error, "#{label} must be a whole number of at least #{min}."}
    end
  end

  defp separately(recipe, markets) do
    results = Enum.map(markets, &{&1, Recipes.run_tests(recipe, &1)})

    case for({market, {:error, reason}} <- results, do: {market, reason}) do
      [] ->
        {:ok, for({_market, {:ok, config}} <- results, do: config)}

      failed ->
        {:error,
         "Couldn't start the tests on " <>
           Enum.map_join(failed, ", ", fn {market, reason} -> "#{market} (#{why(reason)})" end)}
    end
  end

  defp together(recipe, [anchor | _] = markets, mode, rank) do
    basket =
      %{"markets" => markets, "mode" => mode}
      |> then(&if(rank, do: Map.put(&1, "rank", rank), else: &1))

    parameters =
      recipe.definition
      |> Strategies.compose(anchor, recipe.granularity, Strategies.default_sizing())
      |> Map.put("basket", basket)

    case Coordinator.submit_config(%{
           instrument: anchor,
           granularity: recipe.granularity,
           strategy_type: "composite",
           parameters: parameters
         }) do
      {:ok, config} -> {:ok, [config]}
      {:error, reason} -> {:error, "Couldn't start the tests: #{why(reason)}"}
    end
  end

  defp why({:no_history, _first, holdout}),
    do: "no history before #{Calendar.strftime(holdout, "%b %-d, %Y")}"

  defp why(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp why({:no_broker, names}), do: Instruments.without_broker_words(names)
  defp why(other), do: inspect(other)

  @doc """
  What a basket run's results page draws (`StrategyResults.for_baskets/2`):
  `%{stats, holdout?, curve, by_market, from, to}` from the newest look
  that recorded the basket's account (the holdout once it has run, else
  the backtest), best market first; nil before the backtest has finished.
  """
  @spec account(map()) :: map() | nil
  def account(%{stages: stages}) do
    shown =
      Enum.find([stages.holdout, stages.backtest], fn s ->
        is_map(s.stats) and is_map(s.stats["basket"])
      end)

    if shown do
      basket = shown.stats["basket"]

      %{
        stats: shown.stats,
        holdout?: shown == stages.holdout,
        curve: curve(basket),
        by_market: by_market(basket),
        from: parse(basket["from"]),
        to: parse(basket["to"])
      }
    end
  end

  @doc """
  Whether a basket run is judged on calendar-month account returns rather
  than trades: a ranked basket holds positions across re-ranks, so its
  "trades" are few and long. The engine then reports `num_months` (and
  `is_num_months`/`oos_num_months` in the walk-forward), and its months
  minimums replace the trades minimums.
  """
  @spec by_months?(map()) :: boolean()
  def by_months?(%{basket: %{"mode" => "ranked"}}), do: true
  def by_months?(_run), do: false

  @doc """
  How a basket was tested, in words. `choices` (`rank_choices/1`) names
  the ranked value the way the form did; without it the raw key shows.
  """
  @spec mode_words(map(), [{String.t(), String.t()}]) :: String.t()
  def mode_words(basket, choices \\ [])

  def mode_words(%{"mode" => "ranked", "rank" => rank}, choices) do
    by = Enum.find_value(choices, rank["by"], fn {key, label} -> key == rank["by"] && label end)

    {buy, sell} = if rank["buy"] == "lowest", do: {"bottom", "top"}, else: {"top", "bottom"}

    "Ranked every #{rank["every_bars"]} bars by #{by}: buy the #{buy} #{rank["long_top"]}, " <>
      "sell the #{sell} #{rank["short_bottom"]}"
  end

  def mode_words(_together, _choices),
    do: "Together as one account, each market on the recipe's own rules"

  defp curve(%{"curve" => points}) when is_list(points) do
    Enum.map(points, fn p ->
      %{time: parse(p["time"]), equity: p["equity"], drawdown: p["drawdown"]}
    end)
  end

  defp curve(_basket), do: []

  defp by_market(%{"by_market" => rows}) when is_list(rows) do
    rows
    |> Enum.map(fn r ->
      %{
        market: r["market"],
        trades: r["trades"],
        wins: r["wins"],
        account_return: r["account_return"]
      }
    end)
    |> Enum.sort_by(& &1.account_return, :desc)
  end

  defp by_market(_basket), do: []

  defp parse(nil), do: nil

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end
end
