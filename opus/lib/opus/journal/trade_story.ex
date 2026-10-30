defmodule Opus.Journal.TradeStory do
  @moduledoc """
  One live trade told in plain words for the Journal: why it opened, why it
  closed, what it made, how far it moved either way, how it was sized, what
  the fills cost, and what (if anything) to take from it.

  Pure: it reads the `live_trades` row Rust wrote (reasons, best and worst
  moves, sizing audit, fill prices) and the strategy's parameters. Percent
  fields are shares of one (`0.0037` is 0.37%); `pnl` is CAD.
  """

  import OpusWeb.Format, only: [money: 1, pct: 2, signed_money: 1, signed_pct: 2, price: 1]

  alias Opus.Clock
  alias Opus.Trading.ExecutionQuality

  # More slippage than this, in basis points, eats most of a thin intraday edge.
  @slippage_bp 2.0

  @type t :: %{
          result: :win | :loss | :flat | :open,
          headline: String.t(),
          story: [{String.t(), String.t()}],
          numbers: [{String.t(), String.t(), String.t() | nil}],
          takeaways: [String.t()]
        }

  @doc "The whole story of `trade` under `strategy` (`%{parameters: map}`)."
  @spec tell(map(), map()) :: t()
  def tell(trade, strategy) do
    params = strategy[:parameters] || %{}
    size = notional(trade)

    %{
      result: result(trade),
      headline: headline(trade),
      story:
        Enum.reject(
          [
            {"Opened", opened(trade)},
            {"Why", why_opened(trade, params)},
            {"Closed", closed(trade, params)},
            {"Held", held(trade)}
          ],
          fn {_, text} -> is_nil(text) end
        ),
      numbers: numbers(trade, size),
      takeaways: takeaways(trade, size)
    }
  end

  @doc "Why a trade closed, in a few words, for tables."
  @spec exit_label(map()) :: String.t()
  def exit_label(%{status: "open"}), do: "Still open"
  def exit_label(%{exit_reason: nil}), do: "—"

  def exit_label(%{exit_reason: reason} = trade) do
    case exit_kind(reason, trade[:direction]) do
      {:session_close, _} -> "End of the trading day"
      {:faded, key} -> faded_label(key_type(key))
      :stop_loss -> "Stop-loss hit"
      :trailing_stop -> "Trailing stop hit"
      :take_profit -> "Profit target hit"
      :trend_reversal -> "The trend turned"
      :broker -> "Closed by OANDA"
      :other -> reason
    end
  end

  defp faded_label("NoiseArea"), do: "The move faded"
  defp faded_label("MeanReversion"), do: "Back to its average"
  defp faded_label("RsiReversion"), do: "RSI recovered"
  defp faded_label(_type), do: "Its exit rule fired"

  # --- headline -----------------------------------------------------------

  defp result(%{status: "open"}), do: :open
  defp result(%{pnl: pnl}) when is_number(pnl) and pnl > 0.005, do: :win
  defp result(%{pnl: pnl}) when is_number(pnl) and pnl < -0.005, do: :loss
  defp result(%{pnl_percent: p}) when is_number(p) and p > 0, do: :win
  defp result(%{pnl_percent: p}) when is_number(p) and p < 0, do: :loss
  defp result(_trade), do: :flat

  defp headline(%{status: "open"} = t), do: "Open: #{side_word(t)} #{market(t)}"

  defp headline(%{pnl: pnl, pnl_percent: p}) when is_number(pnl) and pnl < 0,
    do: "Lost #{money(-pnl)} (#{signed_pct(p, 2)})"

  defp headline(%{pnl: pnl, pnl_percent: p}) when is_number(pnl),
    do: "Made #{money(pnl)} (#{signed_pct(p, 2)})"

  defp headline(%{pnl_percent: p}) when is_number(p), do: "Closed at #{signed_pct(p, 2)}"
  defp headline(_trade), do: "Closed"

  # --- the story ----------------------------------------------------------

  defp opened(t) do
    verb = if long?(t), do: "Bought", else: "Sold short"

    "#{verb} #{units_text(t)} of #{market(t)} at #{price(t.entry_price)} on #{when_text(t.entry_time)}."
  end

  defp why_opened(%{entry_reason: "Composite " <> _} = t, params) do
    components = get_in(t, [:indicators_at_entry, "components"]) || []

    case Enum.map(components, &component_entry(type_of(params, &1), params, &1, long?(t))) do
      [] -> "Its entry rule fired."
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp why_opened(%{entry_reason: "CrossAbove" <> _}, _params),
    do:
      "Its faster moving average crossed above the slower one: by this strategy's rule, " <>
        "an uptrend starting."

  defp why_opened(%{entry_reason: "CrossBelow" <> _}, _params),
    do:
      "Its faster moving average crossed below the slower one: by this strategy's rule, " <>
        "a downtrend starting."

  defp why_opened(%{entry_reason: "BelowMA: " <> rest}, _params),
    do: stretched(rest, "below", "back up")

  defp why_opened(%{entry_reason: "AboveMA: " <> rest}, _params),
    do: stretched(rest, "above", "back down")

  defp why_opened(%{entry_reason: reason}, _params) when is_binary(reason), do: reason
  defp why_opened(_trade, _params), do: nil

  defp stretched(rest, side, back) do
    case Regex.run(~r/MA(\d+)=[^,]+, deviation=-?([\d.]+)%/, rest) do
      [_, period, deviation] ->
        "The price was #{deviation}% #{side} its #{period}-bar average. " <>
          "The bet: it snaps #{back} toward the average."

      nil ->
        "The price stretched #{side} its average. The bet: it snaps #{back}."
    end
  end

  defp component_entry("NoiseArea", params, key, long?) do
    sessions = get_in(params, ["components", key, "params", "lookback_sessions"])
    over = if sessions, do: ", measured over the last #{sessions} sessions", else: ""
    side = if long?, do: "above", else: "below"

    "The price broke #{side} its noise area: the range it normally stays inside by this " <>
      "time of day#{over}. A break out of that range tends to keep going for the rest of the day."
  end

  defp component_entry("MeanReversion", _params, _key, long?),
    do:
      "The price stretched #{if long?, do: "below", else: "above"} its average. " <>
        "The bet: it snaps back."

  defp component_entry("RsiReversion", _params, _key, long?),
    do:
      "RSI fell deep into #{if long?, do: "oversold", else: "overbought"} territory. " <>
        "The bet: a bounce #{if long?, do: "up", else: "down"}."

  defp component_entry("TrendFollowing", _params, _key, long?),
    do:
      "Its faster moving average crossed #{if long?, do: "above", else: "below"} the slower one: " <>
        "a trend starting, by its rule."

  defp component_entry("Donchian", _params, _key, long?),
    do:
      "The price broke its recent #{if long?, do: "high", else: "low"}: a breakout, by its rule."

  defp component_entry("Macd", _params, _key, long?),
    do: "MACD crossed #{if long?, do: "above", else: "below"} its signal line: momentum turning."

  defp component_entry("Momentum", _params, _key, long?),
    do: "The price has been #{if long?, do: "rising", else: "falling"} over its lookback."

  defp component_entry("MaFilter", _params, _key, long?),
    do: "The price was #{if long?, do: "above", else: "below"} its long-term average (a filter)."

  defp component_entry("EventWindow", _params, _key, _long?),
    do: "It was inside the strategy's scheduled event window."

  defp component_entry(type, _params, key, _long?),
    do: "Its #{type || key} rule signalled an entry."

  defp closed(%{status: "open"}, _params), do: nil

  defp closed(%{exit_reason: reason} = t, params) when is_binary(reason) do
    at = "at #{price(t.exit_price)} on #{when_text(t.exit_time)}"

    case exit_kind(reason, t.direction) do
      {:session_close, _} ->
        "At the end of the trading day, #{at}. This strategy never holds overnight."

      {:faded, key} ->
        "#{faded(type_of(params, key) || key, long?(t))}, #{at}."

      :stop_loss ->
        "It hit its stop-loss #{at}."

      :trailing_stop ->
        "It hit its trailing stop #{at}, after moving in its favour."

      :take_profit ->
        "It hit its profit target #{at}."

      :trend_reversal ->
        "The moving averages crossed back the other way (the trend turned), #{at}."

      :broker ->
        "OANDA closed it, not Auro's rules, #{at}."

      :other ->
        "#{reason}, #{at}."
    end
  end

  defp closed(t, _params), do: "Closed at #{price(t[:exit_price])}."

  defp faded("NoiseArea", long?),
    do:
      "Early: the price fell back #{if long?, do: "below", else: "above"} the edge of its " <>
        "noise area, so the move had faded"

  defp faded("MeanReversion", _long?), do: "The price came back to its average (the target)"
  defp faded("RsiReversion", _long?), do: "RSI recovered (the target)"
  defp faded(_type, _long?), do: "Its exit rule fired"

  defp held(%{entry_time: from, exit_time: to, status: status}) when not is_nil(from) do
    text = OpusWeb.Format.held(from, to)
    if status == "open", do: "#{text} so far.", else: "#{text}."
  end

  defp held(_trade), do: nil

  # --- the numbers --------------------------------------------------------

  defp numbers(t, size) do
    [
      result_row(t),
      move_row(
        "Best point",
        extreme(t[:mfe_pct], t[:pnl_percent]),
        size,
        "the furthest it went in its favour"
      ),
      move_row(
        "Worst point",
        extreme(t[:mae_pct], t[:pnl_percent] && -t[:pnl_percent]) |> negate(),
        size,
        "the furthest it went against"
      ),
      kept_row(t),
      risk_row(t, size),
      size_row(t, size),
      fill_row(
        "Entry fill",
        t.entry_price,
        ExecutionQuality.entry_slippage_bp(t),
        t[:entry_spread]
      ),
      fill_row("Exit fill", t[:exit_price], ExecutionQuality.exit_slippage_bp(t), t[:exit_spread])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp result_row(%{status: "open"}), do: nil

  defp result_row(t),
    do: {"Result", "#{money(t[:pnl])} · #{signed_pct(t[:pnl_percent], 2)}", nil}

  # The recorded best/worst move, but never milder than where it closed.
  defp extreme(nil, _closed), do: nil
  defp extreme(move, closed) when is_number(closed), do: max(move, closed)
  defp extreme(move, _closed), do: move

  defp negate(nil), do: nil
  defp negate(share), do: -share

  defp move_row(_label, nil, _size, _note), do: nil

  defp move_row(label, share, size, note),
    do: {label, "#{signed_pct(share, 2)}#{cad(share, size)}", note}

  defp kept_row(%{pnl_percent: p, mfe_pct: best}) when is_number(p) and p > 0 and best > 0,
    do: {"Kept", pct(min(p / best, 1.0), 0), "of its best gain"}

  defp kept_row(_trade), do: nil

  defp risk_row(%{stop_loss_price: stop, entry_price: entry} = t, size)
       when is_number(stop) and is_number(entry) and entry != 0 do
    share = abs(entry - stop) / entry
    equity = get_in(t, [:sizing_metadata, "equity_at_decision"])

    of_account =
      if equity && size, do: " (#{pct(share * size / equity, 2)} of the account)", else: ""

    risked = if size, do: " (≈ #{money(share * size)})", else: ""

    {"Risked", "#{pct(share, 2)}#{risked}",
     "if the stop at #{price(stop)} had been hit#{of_account}"}
  end

  defp risk_row(_trade, _size), do: nil

  defp size_row(_t, nil), do: nil

  defp size_row(t, size) do
    of_nav = get_in(t, [:sizing_metadata, "notional_pct_of_nav"])
    note = if of_nav, do: "#{pct(of_nav, 0)} of the account", else: nil
    {"Position", "#{money(size)} (#{units_text(t)})", note}
  end

  # Slippage against the fill the backtest assumed; positive is worse.
  defp fill_row(_label, _fill, nil, _spread), do: nil

  defp fill_row(label, fill, bp, spread) do
    word =
      cond do
        abs(bp) < 0.05 -> "what the backtest assumed"
        bp > 0 -> "#{num1(bp)} bp worse than the backtest assumed"
        true -> "#{num1(-bp)} bp better than the backtest assumed"
      end

    note = if is_number(spread), do: "spread #{num1(spread)} points", else: nil
    {label, "#{price(fill)}: #{word}", note}
  end

  # --- what to take from it ------------------------------------------------

  defp takeaways(%{status: "open"}, _size),
    do: ["Still open: its rules decide the exit. Nothing to do by hand."]

  defp takeaways(t, size) do
    [
      stop_takeaway(t, size),
      giveback_takeaway(t),
      slippage_takeaway(t),
      cap_takeaway(t)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        [
          "Nothing stands out: it opened and closed the way its rules say. One trade is mostly " <>
            "luck; judge the strategy on its record across many trades (its Strategies page)."
        ]

      lessons ->
        lessons
    end
  end

  defp stop_takeaway(%{exit_reason: "StopLoss" <> _, pnl: pnl} = t, size) do
    planned = planned_risk(t, size)

    if (is_number(pnl) and planned) && -pnl > planned * 1.25 do
      "It lost #{money(-pnl)}, more than the #{money(planned)} its stop allowed: the price " <>
        "jumped past the stop. Once is bad luck; if it repeats, the stop isn't protecting you."
    else
      "A stop-loss hit is the loss this strategy accepts on purpose, not a mistake. " <>
        "It cost what the sizing planned for."
    end
  end

  defp stop_takeaway(_trade, _size), do: nil

  defp planned_risk(%{stop_loss_price: stop, entry_price: entry}, size)
       when is_number(stop) and is_number(entry) and is_number(size) and entry != 0,
       do: abs(entry - stop) / entry * size

  defp planned_risk(_trade, _size), do: nil

  defp giveback_takeaway(%{pnl_percent: p, mfe_pct: best})
       when is_number(p) and is_number(best) and best > 0.002 and p < best / 2 do
    turned = if p < 0, do: "and still finished at a loss", else: "and kept #{pct(p / best, 0)}"

    "It was up #{signed_pct(best, 2)} at its best #{turned}. Strategies that hold winners " <>
      "to their exit give some back by design. Whether a rule to protect gains would pay is " <>
      "a question for many trades, not one."
  end

  defp giveback_takeaway(_trade), do: nil

  defp slippage_takeaway(t) do
    total =
      [ExecutionQuality.entry_slippage_bp(t), ExecutionQuality.exit_slippage_bp(t)]
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    if total > @slippage_bp do
      "Its fills cost #{num1(total)} bp more than the backtest assumed. Edges like this are " <>
        "a few bp a trade, so this matters if it repeats: Journal → Execution quality tracks it."
    end
  end

  defp cap_takeaway(%{sizing_metadata: %{"clamps_applied" => [_ | _], "raw_units" => raw} = s})
       when is_number(raw) and raw > 0 do
    units = s["clamped_units"]

    "The size limit cut it from #{num2(raw)} units to #{units_text(%{units: units})}, so it made or lost " <>
      "about #{pct(units / raw, 0)} of what the strategy's #{pct(s["risk_pct"] || 0.01, 0)} " <>
      "risk rule asked for."
  end

  defp cap_takeaway(_trade), do: nil

  # --- helpers ------------------------------------------------------------

  # The position's size in CAD: from the realized P&L where there is one,
  # else from the sizing audit.
  defp notional(%{pnl: pnl, pnl_percent: p}) when is_number(pnl) and is_number(p) and p != 0,
    do: abs(pnl / p)

  defp notional(%{sizing_metadata: %{"quote_to_home_rate" => rate}, entry_price: entry} = t)
       when is_number(rate) and is_number(entry),
       do: abs(units(t) * entry * rate)

  defp notional(_trade), do: nil

  defp cad(_share, nil), do: ""
  defp cad(share, size), do: " (≈ #{signed_money(share * size)})"

  defp exit_kind("CompositeExit" <> rest, direction) do
    with [_, json] <- Regex.run(~r/ports=(\{.*\})\)?$/, rest),
         {:ok, ports} <- Jason.decode(json) do
      composite_exit(ports, direction)
    else
      _ -> {:faded, nil}
    end
  end

  defp exit_kind("StopLoss" <> _, _), do: :stop_loss
  defp exit_kind("TrailingStop" <> _, _), do: :trailing_stop
  defp exit_kind("TakeProfit" <> _, _), do: :take_profit
  defp exit_kind("TrendReversal" <> _, _), do: :trend_reversal
  defp exit_kind("ClosedByBroker" <> _, _), do: :broker
  defp exit_kind(_reason, _direction), do: :other

  defp composite_exit(ports, direction) do
    exit_port = if direction == "Short", do: "exit_short", else: "exit_long"

    cond do
      key = find_port(ports, "session_close") -> {:session_close, key}
      key = find_port(ports, exit_port) -> {:faded, key}
      true -> {:faded, ports |> Map.keys() |> List.first()}
    end
  end

  defp find_port(ports, port),
    do: Enum.find_value(ports, fn {key, flags} -> flags[port] == true && key end)

  defp type_of(params, key), do: get_in(params, ["components", key, "type"]) || key_type(key)

  # Older composites name their component by a short key only.
  defp key_type("mr"), do: "MeanReversion"
  defp key_type("na"), do: "NoiseArea"
  defp key_type(_key), do: nil

  defp long?(%{direction: "Short"}), do: false
  defp long?(_trade), do: true

  defp side_word(t), do: if(long?(t), do: "long", else: "short")

  # Currency pairs read as EUR/USD; index and commodity CFDs by their own name.
  @doc "A trade's market as people say it: \"NAS100\", \"AUD/CAD\"."
  @spec market(%{instrument: String.t()}) :: String.t()
  def market(%{instrument: instrument}) do
    case String.split(instrument, "_") do
      [base, quote] when byte_size(base) == 3 -> base <> "/" <> quote
      [name | _] -> name
    end
  end

  defp units(%{units: units}) when is_binary(units) do
    case Float.parse(units) do
      {value, _} -> abs(value)
      :error -> 0.0
    end
  end

  defp units(%{units: units}) when is_number(units), do: abs(units)
  defp units(_trade), do: 0.0

  defp units_text(t) do
    case units(t) do
      1.0 -> "1 unit"
      n -> "#{num2(n)} units"
    end
  end

  defp when_text(nil), do: "—"

  defp when_text(at),
    do: at |> Clock.local(Clock.display_zone()) |> Calendar.strftime("%a %b %-d, %-I:%M %p %Z")

  defp num1(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp num2(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp num2(value), do: :erlang.float_to_binary(value / 1, decimals: 2)
end
