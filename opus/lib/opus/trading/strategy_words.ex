defmodule Opus.Trading.StrategyWords do
  @moduledoc """
  A strategy recipe in plain words: when it buys, sells short, closes each,
  where the stop goes and how long it can hold. Each component type's
  ports are described from its settings, matching what the Rust component
  computes (`auro_be/src/engine/<component>.rs`). A port this module
  doesn't know comes back as its raw name (`"r.long"`), so a new component
  shows up readable-enough instead of breaking the page.
  """

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

  defp port("RsiReversion", port, %{"rsi_period" => n} = p, _g) do
    case port do
      "long" -> "RSI(#{n}) is below #{num(p["oversold"])}"
      "short" -> "RSI(#{n}) is above #{num(p["overbought"])}"
      "exit_long" -> "RSI(#{n}) is back to 50 or higher"
      "exit_short" -> "RSI(#{n}) is back to 50 or lower"
      _ -> nil
    end
  end

  defp port("MaFilter", port, %{"period" => n} = p, g) do
    average = "its #{ma_type(p["ma_type"])} average over #{bars(g, n)}"

    case port do
      "above" -> "the price is above #{average}"
      "below" -> "the price is below #{average}"
      _ -> nil
    end
  end

  defp port("NoiseArea", port, %{"lookback_sessions" => n}, _g) do
    band = "the noise band (the usual move from the open, over the last #{n} sessions)"

    case port do
      "long" -> "the price breaks above #{band}"
      "short" -> "the price breaks below #{band}"
      "exit_long" -> "the price falls back below the band or the day's average price (VWAP)"
      "exit_short" -> "the price rises back above the band or the day's average price (VWAP)"
      "session_close" -> "the US session ends (16:00 New York)"
      _ -> nil
    end
  end

  defp port("MeanReversion", port, %{"ma_period" => n, "rsi_period" => r} = p, g) do
    away = "#{num(p["entry_z_threshold"])} standard deviations"
    average = "its average over #{bars(g, n)}"
    stop_z = num(p["stop_z_threshold"])

    case port do
      "long" ->
        "the price is more than #{away} below #{average} and RSI(#{r}) is below #{num(p["rsi_oversold"])}"

      "short" ->
        "the price is more than #{away} above #{average} and RSI(#{r}) is above #{num(p["rsi_overbought"])}"

      "exit_long" ->
        "the price is back up to #{average}, or falls more than #{stop_z} standard deviations below it"

      "exit_short" ->
        "the price is back down to #{average}, or rises more than #{stop_z} standard deviations above it"

      _ ->
        nil
    end
  end

  defp port("TrendFollowing", port, %{"fast_period" => f, "slow_period" => s}, g) do
    pair = "the average over #{bars(g, f)}"
    slow = "the one over #{bars(g, s)}"

    case port do
      "bullish" -> "#{pair} is above #{slow}"
      "bearish" -> "#{pair} is below #{slow}"
      "bullish_cross" -> "#{pair} crosses above #{slow}"
      "bearish_cross" -> "#{pair} crosses below #{slow}"
      _ -> nil
    end
  end

  defp port("Macd", port, _p, _g) do
    case port do
      "bullish" -> "MACD is above its signal line"
      "bearish" -> "MACD is below its signal line"
      "bullish_cross" -> "MACD crosses above its signal line"
      "bearish_cross" -> "MACD crosses below its signal line"
      _ -> nil
    end
  end

  defp port("Donchian", port, %{"entry_period" => e, "exit_period" => x}, g) do
    case port do
      "breakout_long" -> "the price breaks above its #{bars(g, e)} high"
      "breakout_short" -> "the price breaks below its #{bars(g, e)} low"
      "exit_long" -> "the price breaks below its #{bars(g, x)} low"
      "exit_short" -> "the price breaks above its #{bars(g, x)} high"
      _ -> nil
    end
  end

  defp port("Momentum", port, %{"lookback" => n}, g) do
    case port do
      "up" -> "the price is higher than #{bars(g, n)} ago"
      "down" -> "the price is lower than #{bars(g, n)} ago"
      _ -> nil
    end
  end

  defp port("EventWindow", port, _p, _g) do
    case port do
      "in_window" -> "it's inside the event window"
      "out_of_window" -> "it's outside the event window"
      _ -> nil
    end
  end

  defp port(_type, _port, _params, _g), do: nil

  defp stop(%{"type" => "AtrMultiple", "params" => %{"k" => k} = p}, _components, g) do
    "#{num(k)} × the average range (ATR over #{bars(g, p["period"] || 14)}) away from the entry"
  end

  defp stop(%{"type" => "FixedPct", "params" => %{"pct" => pct}}, _components, _g),
    do: "#{percent(abs(pct))} away from the entry"

  defp stop(%{"type" => "FromComponent", "params" => %{"component" => name}}, components, _g) do
    case components[name] do
      %{"type" => "NoiseArea"} ->
        "the other side of the noise band"

      %{"type" => "MeanReversion", "params" => %{"stop_z_threshold" => z}} ->
        "#{num(z)} standard deviations past the average"

      _ ->
        "set by #{name}"
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

  defp ma_type("ema"), do: "exponential"
  defp ma_type(_), do: "simple"

  defp percent(share), do: "#{num(share * 100)}%"

  defp num(n) when is_integer(n), do: Integer.to_string(n)

  defp num(n) when is_float(n) do
    rounded = Float.round(n, 2)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: to_string(rounded)
  end

  defp num(other), do: to_string(other)
end
