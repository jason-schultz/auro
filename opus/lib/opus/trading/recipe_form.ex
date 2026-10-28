defmodule Opus.Trading.RecipeForm do
  @moduledoc """
  The strategy builder's form, and the conversion between it and a recipe
  definition (the JSON in `strategies.definition`).

  A form is plain maps of strings, the way a browser form sends it back:

      %{"name" => ..., "granularity" => "D", "notes" => ...,
        "components" => [%{"key" => "r", "type" => "RsiReversion", "params" => %{...}}],
        "rules" => %{"entry_long" => %{"mode" => "and", "refs" => ["r.long", "t.above"]}, ...},
        "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => "3", "period" => "14"}},
        "hold" => "10"}

  A rule is one list of single rules joined by "all of" (`and`) or "any of"
  (`or`). A recipe whose rules nest deeper than that can't be edited here
  (`from_definition/2` says `:too_complex`). Keys the form doesn't know
  (`version`, `strategy_id`, …) are kept from the original definition.

  The blocks themselves, their settings and defaults are `Opus.Trading.Blocks`.
  """

  alias Opus.Trading.Blocks

  @rules ~w(entry_long entry_short exit_long exit_short)
  @paths %{
    "entry_long" => ["entry", "long"],
    "entry_short" => ["entry", "short"],
    "exit_long" => ["exit", "long"],
    "exit_short" => ["exit", "short"]
  }

  # Components that can place their own stop (`StopConfig::FromComponent`).
  @own_stop ~w(NoiseArea MeanReversion)

  @doc "The rule slots, in order: entry_long, entry_short, exit_long, exit_short."
  @spec rules() :: [String.t()]
  def rules, do: @rules

  @doc "Component types that can set the stop themselves."
  @spec own_stop() :: [String.t()]
  def own_stop, do: @own_stop

  @doc "A new strategy's starting form: daily bars, no blocks, an ATR stop."
  @spec new() :: map()
  def new do
    %{
      "name" => "",
      "granularity" => "D",
      "notes" => "",
      "components" => [],
      "rules" => Map.new(@rules, &{&1, %{"mode" => "and", "refs" => []}}),
      "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => "3", "period" => "14"}},
      "hold" => ""
    }
  end

  @doc """
  Ready-made strategies to start from, each a complete form a beginner can
  open, look at and change: `[%{id, name, description, form}]`.
  """
  @spec templates() :: [map()]
  def templates do
    [
      %{
        id: "dip_in_uptrend",
        name: "Buy dips in an uptrend",
        description:
          "Waits until the price has dropped hard for a couple of days while the longer trend is still up, " <>
            "buys, and sells when it bounces back. Daily bars.",
        form:
          starter("Buy dips in an uptrend", "D", [{"RsiReversion", %{}}, {"MaFilter", %{}}], %{
            "entry_long" => {"and", ["r.long", "t.above"]},
            "exit_long" => {"and", ["r.exit_long"]}
          })
          |> Map.put("hold", "10")
      },
      %{
        id: "breakout",
        name: "Ride a breakout",
        description:
          "Buys when the price breaks above its 20-day high and sells short when it breaks below its 20-day low; " <>
            "each trade closes when the price breaks the 10-day range the other way. Daily bars.",
        form:
          starter("Ride a breakout", "D", [{"Donchian", %{}}], %{
            "entry_long" => {"and", ["dc.breakout_long"]},
            "exit_long" => {"and", ["dc.exit_long"]},
            "entry_short" => {"and", ["dc.breakout_short"]},
            "exit_short" => {"and", ["dc.exit_short"]}
          })
      },
      %{
        id: "trend_cross",
        name: "Follow the trend",
        description:
          "Buys when a fast average crosses above a slow one and sells short when it crosses below; " <>
            "it stays in until the averages cross back. Daily bars.",
        form:
          starter(
            "Follow the trend",
            "D",
            [{"TrendFollowing", %{"fast_period" => "20", "slow_period" => "100"}}],
            %{
              "entry_long" => {"and", ["tf.bullish_cross"]},
              "exit_long" => {"and", ["tf.bearish_cross"]},
              "entry_short" => {"and", ["tf.bearish_cross"]},
              "exit_short" => {"and", ["tf.bullish_cross"]}
            }
          )
      },
      %{
        id: "intraday_breakout",
        name: "Intraday breakout (US indices)",
        description:
          "Buys or sells short when the price moves further from the US open than it usually does by that time, " <>
            "and is always out by the 16:00 close. 5-minute bars.",
        form:
          starter("Intraday breakout", "M5", [{"NoiseArea", %{}}], %{
            "entry_long" => {"and", ["na.long"]},
            "exit_long" => {"or", ["na.exit_long", "na.session_close"]},
            "entry_short" => {"and", ["na.short"]},
            "exit_short" => {"or", ["na.exit_short", "na.session_close"]}
          })
          |> Map.put("stop", %{"type" => "FromComponent", "params" => %{"component" => "na"}})
      }
    ]
  end

  @doc "A template's form by id, or nil."
  @spec template(String.t()) :: map() | nil
  def template(id), do: Enum.find_value(templates(), &(&1.id == id && &1.form))

  defp starter(name, granularity, blocks, rules) do
    form =
      Enum.reduce(
        blocks,
        Map.merge(new(), %{"name" => name, "granularity" => granularity}),
        fn {type, params}, form ->
          form
          |> add_component(type)
          |> update_in(["components", Access.at(-1), "params"], &Map.merge(&1, params))
        end
      )

    Enum.reduce(rules, form, fn {slot, {mode, refs}}, form ->
      put_in(form, ["rules", slot], %{"mode" => mode, "refs" => refs})
    end)
  end

  @doc "A block of `type` added to the form under a key no other block uses."
  @spec add_component(map(), String.t()) :: map()
  def add_component(form, type) do
    %{key: base, params: params} = Blocks.get(type)
    taken = MapSet.new(form["components"], & &1["key"])

    key =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&if(&1 == 1, do: base, else: "#{base}#{&1}"))
      |> Enum.find(&(not MapSet.member?(taken, &1)))

    component = %{
      "key" => key,
      "type" => type,
      "params" => Map.new(params, &{&1.key, to_string(&1.default)})
    }

    Map.update!(form, "components", &(&1 ++ [component]))
  end

  @doc "The form without the block keyed `key`, and without any rule that used it."
  @spec remove_component(map(), String.t()) :: map()
  def remove_component(form, key) do
    prefix = key <> "."

    form
    |> Map.update!("components", &Enum.reject(&1, fn c -> c["key"] == key end))
    |> Map.update!("rules", fn rules ->
      Map.new(rules, fn {slot, rule} ->
        {slot,
         Map.update!(rule, "refs", &Enum.reject(&1, fn r -> String.starts_with?(r, prefix) end))}
      end)
    end)
  end

  @doc """
  Every single rule the form's blocks offer, as `{ref, words}`, for the
  rule pickers (`{"r.long", "RSI(2) is below 20"}`).
  """
  @spec choices(map()) :: [{String.t(), String.t()}]
  def choices(form) do
    definition = to_definition(form, %{})

    for c <- form["components"], %{ports: ports} <- [Blocks.get(c["type"])], port <- ports do
      ref = "#{c["key"]}.#{port}"
      {ref, Opus.Trading.StrategyWords.phrase(definition, ref, form["granularity"])}
    end
  end

  @doc """
  `choices/1` grouped by block, for a picker: `[{"RSI", [{ref, words}, …]}, …]`.
  """
  @spec grouped_choices(map()) :: [{String.t(), [{String.t(), String.t()}]}]
  def grouped_choices(form) do
    by_key = Map.new(form["components"], &{&1["key"], Blocks.get(&1["type"]).name})

    form
    |> choices()
    |> Enum.chunk_by(fn {ref, _} -> ref |> String.split(".") |> hd() end)
    |> Enum.map(fn [{ref, _} | _] = group ->
      {by_key[ref |> String.split(".") |> hd()], group}
    end)
  end

  @doc "The form with `ref` added to a rule slot, once."
  @spec add_ref(map(), String.t(), String.t()) :: map()
  def add_ref(form, slot, ref) do
    update_in(form, ["rules", slot, "refs"], fn refs ->
      if ref in refs, do: refs, else: refs ++ [ref]
    end)
  end

  @doc "The form with `ref` taken out of a rule slot."
  @spec remove_ref(map(), String.t(), String.t()) :: map()
  def remove_ref(form, slot, ref),
    do: update_in(form, ["rules", slot, "refs"], &List.delete(&1, ref))

  @doc """
  The form for a recipe, or `{:error, :too_complex}` when a rule nests
  deeper than "all of" or "any of" a list, or a block type isn't one the
  builder offers.
  """
  @spec from_definition(map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :too_complex}
  def from_definition(definition, name, granularity, notes) do
    with {:ok, components} <- components(definition["components"] || %{}),
         {:ok, rules} <- rule_slots(definition) do
      {:ok,
       %{
         "name" => name,
         "granularity" => granularity,
         "notes" => notes || "",
         "components" => components,
         "rules" => rules,
         "stop" => stop_form(definition["stop"]),
         "hold" => to_string(definition["max_hold_bars"] || "")
       }}
    end
  end

  defp components(components) do
    components
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {key, %{"type" => type} = c}, {:ok, acc} ->
      case Blocks.get(type) do
        nil ->
          {:halt, {:error, :too_complex}}

        _block ->
          params = Map.new(c["params"] || %{}, fn {k, v} -> {k, to_string(v)} end)
          {:cont, {:ok, acc ++ [%{"key" => key, "type" => type, "params" => params}]}}
      end
    end)
  end

  defp rule_slots(definition) do
    Enum.reduce_while(@rules, {:ok, %{}}, fn slot, {:ok, acc} ->
      case rule(get_in(definition, @paths[slot])) do
        {:ok, rule} -> {:cont, {:ok, Map.put(acc, slot, rule)}}
        :error -> {:halt, {:error, :too_complex}}
      end
    end)
  end

  defp rule(nil), do: {:ok, %{"mode" => "and", "refs" => []}}
  defp rule(ref) when is_binary(ref), do: {:ok, %{"mode" => "and", "refs" => [ref]}}

  defp rule(%{} = expr) when map_size(expr) == 1 do
    case Enum.at(expr, 0) do
      {mode, refs} when mode in ["and", "or"] and is_list(refs) ->
        if Enum.all?(refs, &is_binary/1),
          do: {:ok, %{"mode" => mode, "refs" => refs}},
          else: :error

      _ ->
        :error
    end
  end

  defp rule(_), do: :error

  # The form shows a fixed stop as a positive percent; the recipe stores a
  # negative fraction (-0.02 for 2%).
  defp stop_form(%{"type" => "FixedPct", "params" => %{"pct" => pct}}),
    do: %{"type" => "FixedPct", "params" => %{"pct" => to_string(abs(pct) * 100)}}

  defp stop_form(%{"type" => type, "params" => params}),
    do: %{"type" => type, "params" => Map.new(params, fn {k, v} -> {k, to_string(v)} end)}

  defp stop_form(_), do: new()["stop"]

  @doc """
  The recipe definition for a form, merged over `base` (the original
  definition when editing, `%{}` for a new one) so keys the form doesn't
  know survive. Numbers typed as text become numbers; an empty rule is
  left out.
  """
  @spec to_definition(map(), map()) :: map()
  def to_definition(form, base) do
    entry_exit =
      Enum.reduce(@rules, %{"entry" => %{}, "exit" => %{}}, fn slot, acc ->
        [group, side] = @paths[slot]

        case expression(form["rules"][slot]) do
          nil -> acc
          expr -> put_in(acc, [group, side], expr)
        end
      end)

    base
    |> Map.drop(["instrument", "granularity", "sizing"])
    |> Map.merge(%{
      "version" => base["version"] || "1",
      "strategy_name" => form["name"],
      "components" =>
        Map.new(form["components"], fn c ->
          {c["key"], %{"type" => c["type"], "params" => cast_params(c["type"], c["params"])}}
        end),
      "entry" => entry_exit["entry"],
      "exit" => entry_exit["exit"],
      "stop" => %{"type" => form["stop"]["type"], "params" => cast_stop(form["stop"])},
      "max_hold_bars" => integer(form["hold"])
    })
  end

  defp expression(%{"refs" => []}), do: nil
  defp expression(%{"refs" => [ref]}), do: ref
  defp expression(%{"mode" => mode, "refs" => refs}), do: %{mode => refs}
  defp expression(_), do: nil

  defp cast_params(type, params) do
    case Blocks.get(type) do
      nil ->
        params

      %{params: specs} ->
        Map.new(specs, fn spec -> {spec.key, cast(spec.kind, params[spec.key], spec.default)} end)
    end
  end

  defp cast_stop(%{"type" => "AtrMultiple", "params" => p}),
    do: %{"k" => number(p["k"]) || 3.0, "period" => integer(p["period"]) || 14}

  defp cast_stop(%{"type" => "FixedPct", "params" => p}),
    do: %{"pct" => -abs((number(p["pct"]) || 2.0) / 100)}

  defp cast_stop(%{"type" => "FromComponent", "params" => p}),
    do: %{"component" => p["component"]}

  defp cast(:int, value, default), do: integer(value) || default
  defp cast(:float, value, default), do: number(value) || default / 1

  defp cast({:select, options}, value, default),
    do: if(value in Enum.map(options, &elem(&1, 1)), do: value, else: default)

  defp integer(nil), do: nil
  defp integer(value) when is_integer(value), do: value

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(nil), do: nil
  defp number(value) when is_number(value), do: value / 1

  defp number(value) do
    case Float.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
