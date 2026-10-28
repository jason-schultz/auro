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

  `catalog/0` lists the signal blocks with their settings and what each
  one's outputs mean; the settings and defaults mirror the Rust components
  (`auro_be/src/engine/<component>.rs`).
  """

  @catalog [
    %{
      type: "RsiReversion",
      name: "RSI",
      hint: "How stretched the last few bars were, 0 to 100",
      key: "r",
      params: [
        %{key: "rsi_period", label: "Bars to look at", kind: :int, default: 2},
        %{key: "oversold", label: "Oversold below", kind: :float, default: 20},
        %{key: "overbought", label: "Overbought above", kind: :float, default: 80}
      ],
      ports: ~w(long short exit_long exit_short)
    },
    %{
      type: "MaFilter",
      name: "Moving average",
      hint: "Is the price above or below its average?",
      key: "t",
      params: [
        %{key: "period", label: "Bars", kind: :int, default: 100},
        %{
          key: "ma_type",
          label: "Kind",
          kind: {:select, [{"Simple", "sma"}, {"Exponential", "ema"}]},
          default: "sma"
        }
      ],
      ports: ~w(above below)
    },
    %{
      type: "NoiseArea",
      name: "Noise band",
      hint: "Breaks out of the usual range from the US open (intraday)",
      key: "na",
      params: [
        %{key: "lookback_sessions", label: "Sessions to average", kind: :int, default: 14},
        %{key: "band_mult", label: "Band width ×", kind: :float, default: 1.0}
      ],
      ports: ~w(long short exit_long exit_short session_close)
    },
    %{
      type: "Donchian",
      name: "Breakout channel",
      hint: "A new high or low over the last N bars",
      key: "dc",
      params: [
        %{key: "entry_period", label: "Breakout over (bars)", kind: :int, default: 20},
        %{key: "exit_period", label: "Exit over (bars)", kind: :int, default: 10}
      ],
      ports: ~w(breakout_long breakout_short exit_long exit_short)
    },
    %{
      type: "TrendFollowing",
      name: "Average crossover",
      hint: "A fast average crossing a slow one",
      key: "tf",
      params: [
        %{key: "fast_period", label: "Fast (bars)", kind: :int, default: 50},
        %{key: "slow_period", label: "Slow (bars)", kind: :int, default: 200},
        %{
          key: "ma_type",
          label: "Kind",
          kind: {:select, [{"Simple", "sma"}, {"Exponential", "ema"}]},
          default: "sma"
        }
      ],
      ports: ~w(bullish bearish bullish_cross bearish_cross)
    },
    %{
      type: "Macd",
      name: "MACD",
      hint: "MACD crossing its signal line",
      key: "m",
      params: [
        %{key: "fast_period", label: "Fast", kind: :int, default: 12},
        %{key: "slow_period", label: "Slow", kind: :int, default: 26},
        %{key: "signal_period", label: "Signal", kind: :int, default: 9}
      ],
      ports: ~w(bullish bearish bullish_cross bearish_cross)
    },
    %{
      type: "Momentum",
      name: "Momentum",
      hint: "Higher or lower than N bars ago",
      key: "mo",
      params: [%{key: "lookback", label: "Bars back", kind: :int, default: 20}],
      ports: ~w(up down)
    },
    %{
      type: "MeanReversion",
      name: "Stretch from average",
      hint: "Mean reversion: far from the average and RSI agrees",
      key: "mr",
      params: [
        %{key: "ma_period", label: "Average over (bars)", kind: :int, default: 20},
        %{key: "entry_z_threshold", label: "Deviations to enter", kind: :float, default: 2.0},
        %{key: "stop_z_threshold", label: "Deviations to stop", kind: :float, default: 3.0},
        %{key: "rsi_period", label: "RSI bars", kind: :int, default: 14},
        %{key: "rsi_oversold", label: "RSI oversold", kind: :float, default: 30},
        %{key: "rsi_overbought", label: "RSI overbought", kind: :float, default: 70}
      ],
      ports: ~w(long short exit_long exit_short)
    }
  ]

  @rules ~w(entry_long entry_short exit_long exit_short)
  @paths %{
    "entry_long" => ["entry", "long"],
    "entry_short" => ["entry", "short"],
    "exit_long" => ["exit", "long"],
    "exit_short" => ["exit", "short"]
  }

  # Components that can place their own stop (`StopConfig::FromComponent`).
  @own_stop ~w(NoiseArea MeanReversion)

  @doc "The signal blocks the builder offers."
  @spec catalog() :: [map()]
  def catalog, do: @catalog

  @doc "The block for a component type, or nil."
  @spec block(String.t()) :: map() | nil
  def block(type), do: Enum.find(@catalog, &(&1.type == type))

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

  @doc "A block of `type` added to the form under a key no other block uses."
  @spec add_component(map(), String.t()) :: map()
  def add_component(form, type) do
    %{key: base, params: params} = block(type)
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

    for c <- form["components"], %{ports: ports} <- [block(c["type"])], port <- ports do
      ref = "#{c["key"]}.#{port}"
      {ref, Opus.Trading.StrategyWords.phrase(definition, ref, form["granularity"])}
    end
  end

  @doc """
  `choices/1` grouped by block, for a picker: `[{"RSI", [{ref, words}, …]}, …]`.
  """
  @spec grouped_choices(map()) :: [{String.t(), [{String.t(), String.t()}]}]
  def grouped_choices(form) do
    by_key = Map.new(form["components"], &{&1["key"], block(&1["type"]).name})

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
      case block(type) do
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
    case block(type) do
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
