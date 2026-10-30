defmodule Opus.Trading.StrategyWords do
  @moduledoc """
  A strategy recipe in plain words: when it buys, sells short, closes each,
  where the stop goes and how long it can hold. Each block's ports read as
  the words the engine's block catalog gives them (`Opus.Trading.Blocks`),
  filled in from the block's settings; this module adds the sentence glue
  (and, or, time rules, stops, hold limits). A port it can't put in words
  comes back as its raw name (`"r.long"`), so an unknown block shows up
  readable-enough instead of breaking the page.
  """

  alias Opus.Trading.Blocks

  @bar %{
    "M1" => {"1-minute bar", "1-minute bars"},
    "M5" => {"5-minute bar", "5-minute bars"},
    "M15" => {"15-minute bar", "15-minute bars"},
    "H1" => {"hour", "hours"},
    "H4" => {"4-hour bar", "4-hour bars"},
    "D" => {"day", "days"}
  }

  @doc """
  The recipe's rules as `{label, sentence}` pairs, in the order a trade
  lives: open, close, stop, hold limit. Rules the recipe doesn't have are
  left out; a recipe with no short side says so.
  """
  @spec rules(map(), String.t()) :: [{String.t(), String.t()}]
  def rules(definition, granularity) when is_map(definition) do
    components = definition["components"] || %{}
    say = &expression(&1, components, granularity)

    [
      {"Buy when", say.(get_in(definition, ["entry", "long"]))},
      {"Sell short when", say.(get_in(definition, ["entry", "short"]))},
      {"Close the buy when", say.(get_in(definition, ["exit", "long"]))},
      {"Close the short when", say.(get_in(definition, ["exit", "short"]))},
      {"Stop", stop(definition["stop"], components, granularity)},
      {"Hold limit", hold(definition["max_hold_bars"], granularity)},
      {"Direction", direction(definition["entry"])}
    ]
    |> Enum.reject(fn {_label, text} -> is_nil(text) end)
  end

  @doc "One rule of a recipe (`\"r.long\"`) in plain words."
  @spec phrase(map(), String.t(), String.t()) :: String.t()
  def phrase(definition, ref, granularity),
    do: expression(ref, definition["components"] || %{}, granularity)

  @doc "The single rules a selector is built from, in order (`[\"r.long\", \"t.above\"]`)."
  @spec refs(term()) :: [String.t()]
  def refs(ref) when is_binary(ref), do: [ref]
  def refs(%{"and" => parts}), do: Enum.flat_map(parts, &refs/1)
  def refs(%{"or" => parts}), do: Enum.flat_map(parts, &refs/1)
  def refs(%{"not" => part}), do: refs(part)
  def refs(%{"within" => _, "rule" => part}), do: refs(part)
  def refs(%{"ago" => _, "rule" => part}), do: refs(part)
  def refs(_), do: []

  @doc """
  A selector (`entry.long`, `exit.short`, …) in plain words, or nil when
  the recipe doesn't have it.
  """
  @spec selector(map(), [String.t()], String.t()) :: String.t() | nil
  def selector(definition, path, granularity),
    do: expression(get_in(definition, path), definition["components"] || %{}, granularity)

  @doc "An assignment's sizing in plain words."
  @spec sizing(map() | nil) :: String.t()
  def sizing(%{"type" => "RiskPct", "params" => %{"pct" => pct} = params}) do
    "Risks #{percent(pct)} of the account per trade" <>
      case params["max_notional_pct"] do
        nil -> ""
        cap -> ", with the position capped at #{percent(cap)} of the account"
      end
  end

  def sizing(nil), do: "No sizing set"
  def sizing(%{"type" => type}), do: type

  @doc "The recipe's timeframe in plain words (\"daily bars\")."
  @spec timeframe(String.t()) :: String.t()
  def timeframe("D"), do: "daily bars"
  def timeframe("H1"), do: "hourly bars"

  def timeframe(granularity) do
    {_one, many} = Map.get(@bar, granularity, {"bar", "bars"})
    many
  end

  defp expression(nil, _components, _granularity), do: nil

  defp expression(%{"and" => parts}, components, granularity),
    do: Enum.map_join(parts, " and ", &expression(&1, components, granularity))

  defp expression(%{"or" => parts}, components, granularity),
    do: Enum.map_join(parts, ", or ", &expression(&1, components, granularity))

  defp expression(%{"not" => part}, components, granularity),
    do: "not (" <> expression(part, components, granularity) <> ")"

  # Time rules (the engine's `PortRef::Within` / `Ago`): "within 1" is the
  # rule itself; otherwise the time comes first, so it reads the same over
  # any rule, one condition or several.
  defp expression(%{"within" => 1, "rule" => part}, components, granularity),
    do: expression(part, components, granularity)

  defp expression(%{"within" => n, "rule" => part}, components, granularity),
    do:
      "at some point in the last #{bars(granularity, n)}, " <>
        timed(part, components, granularity)

  defp expression(%{"ago" => n, "rule" => part}, components, granularity),
    do: "#{bars(granularity, n)} ago, " <> timed(part, components, granularity)

  defp expression(ref, components, granularity) when is_binary(ref) do
    with [name, port] <- String.split(ref, ".", parts: 2),
         %{"type" => type} = component <- components[name],
         text when is_binary(text) <- port(type, port, component["params"] || %{}, granularity) do
      text
    else
      _ -> ref
    end
  end

  defp expression(other, _components, _granularity), do: inspect(other)

  # Several conditions under one time go in brackets, so the time covers them all.
  defp timed(%{} = part, components, granularity)
       when is_map_key(part, "and") or is_map_key(part, "or"),
       do: "(" <> expression(part, components, granularity) <> ")"

  defp timed(part, components, granularity), do: expression(part, components, granularity)

  # A block's port in words: its template from the block catalog
  # (`Opus.Trading.Blocks`) filled in from the block's settings. Nil when
  # the block or port is unknown, or a setting it names has no value.
  defp port(type, port, params, g) do
    with %{words: words} = block <- Blocks.any(type),
         template when is_binary(template) <- words[port] do
      fill(template, block, params, g)
    end
  end

  # `{key}` is a setting's value (or the words its `reads` cases give),
  # `{key:bars}` a count of bars, `{key:bars|1}` the same falling back to 1
  # when empty (`auro_be/src/engine/catalog.rs`). A setting the recipe
  # leaves out reads as its default.
  @placeholder ~r/\{(\w+)(?::(\w+))?(?:\|([^}]*))?\}/

  defp fill(template, block, params, g) do
    values =
      Map.new(Regex.scan(@placeholder, template), fn [whole, key | rest] ->
        {whole, setting(block, params, g, key, Enum.at(rest, 0, ""), Enum.at(rest, 1, ""))}
      end)

    if Enum.all?(values, fn {_whole, text} -> is_binary(text) end),
      do: Regex.replace(@placeholder, template, &values[&1])
  end

  defp setting(block, params, g, key, format, fallback) do
    spec = Enum.find(block.params, %{default: nil, reads: []}, &(&1.key == key))
    value = Enum.find([params[key], spec.default, fallback(fallback)], &(not is_nil(&1)))

    cond do
      format == "bars" -> value && bars(g, value)
      spec.reads != [] -> reads(spec.reads, value)
      true -> value && num(value)
    end
  end

  defp fallback(""), do: nil

  defp fallback(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> text
    end
  end

  defp reads(cases, value) do
    Enum.find_value(cases, fn %{"when" => w, "text" => text} ->
      if reads?(w, value), do: String.replace(text, "{}", num(value))
    end)
  end

  defp reads?(%{"is" => v}, value), do: v === value
  defp reads?(%{"above" => n}, value), do: is_number(value) and value > n
  defp reads?("otherwise", _value), do: true

  defp stop(%{"type" => "AtrMultiple", "params" => %{"k" => k} = p}, _components, g) do
    "#{num(k)} × the average range (ATR over #{bars(g, p["period"] || 14)}) away from the entry"
  end

  defp stop(%{"type" => "FixedPct", "params" => %{"pct" => pct}}, _components, _g),
    do: "#{percent(abs(pct))} away from the entry"

  defp stop(%{"type" => "FromComponent", "params" => %{"component" => name}}, components, g) do
    with %{"type" => type} = component <- components[name],
         %{stop: template} = block when is_binary(template) <- Blocks.any(type),
         text when is_binary(text) <- fill(template, block, component["params"] || %{}, g) do
      text
    else
      _ -> "set by #{name}"
    end
  end

  defp stop(nil, _components, _g), do: "none"
  defp stop(%{"type" => type}, _components, _g), do: type

  defp hold(nil, _g), do: nil
  defp hold(n, g), do: "closes after #{bars(g, n)} if nothing else has"

  defp direction(%{"long" => _, "short" => _}), do: nil
  defp direction(%{"long" => _}), do: "buys only; it never sells short"
  defp direction(%{"short" => _}), do: "sells short only; it never buys"
  defp direction(_), do: nil

  defp bars(granularity, n) do
    {one, many} = Map.get(@bar, granularity, {"bar", "bars"})
    if n == 1, do: "1 #{one}", else: "#{n} #{many}"
  end

  defp percent(share), do: "#{num(share * 100)}%"

  defp num(n) when is_integer(n), do: Integer.to_string(n)

  defp num(n) when is_float(n) do
    rounded = Float.round(n, 2)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: to_string(rounded)
  end

  defp num(other), do: to_string(other)
end
