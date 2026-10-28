defmodule Opus.Trading.SignalChart do
  @moduledoc """
  Shapes the engine's signal preview (`Opus.Auro.Client.signal_preview/2`)
  for a chart: the candles, each trade the rules would have made with its
  buy and sell markers, and one strip per rule showing the bars it was
  true on, so a page can show why each signal fired.

  Pure: the preview body and the recipe in, plain maps out. Indexes count
  from the first candle in the window.
  """

  alias Opus.Trading.StrategyWords

  @type trade :: %{
          id: non_neg_integer(),
          direction: String.t(),
          entry_index: non_neg_integer(),
          entry_at: DateTime.t(),
          entry_price: float(),
          exit_index: non_neg_integer() | nil,
          exit_at: DateTime.t() | nil,
          exit_price: float() | nil,
          reason: String.t() | nil,
          return: float() | nil
        }

  @doc """
  `%{candles, trades, markers, spans, lanes}` from a preview body and the
  recipe definition it ran. A marker is `%{index, kind: :buy | :sell,
  price, trade}`; a span is the bars a trade was open; a lane is
  `%{ref, label, role: :buy | :sell, runs: [{from, to}]}` (the role is the trade action the rule leads to).
  """
  @spec shape(map(), map(), String.t()) :: map()
  def shape(%{"bars" => bars, "signals" => signals}, definition, granularity) do
    candles = Enum.map(bars, &candle/1)
    index = candles |> Enum.with_index() |> Map.new(fn {c, i} -> {c.time, i} end)
    trades = trades(signals, index)

    %{
      candles: candles,
      trades: trades,
      markers: Enum.flat_map(trades, &markers/1),
      spans: Enum.map(trades, &{&1.entry_index, &1.exit_index || length(candles) - 1}),
      lanes: lanes(bars, definition, granularity)
    }
  end

  defp candle(bar) do
    %{
      time: datetime(bar["time"]),
      open: bar["open"],
      high: bar["high"],
      low: bar["low"],
      close: bar["close"]
    }
  end

  defp datetime(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  # Signals come in pairs, entry then exit; an entry with no exit is the
  # trade still open at the end of the window.
  defp trades(signals, index) do
    signals
    |> Enum.chunk_while(
      nil,
      fn
        %{"kind" => "entry"} = entry, nil -> {:cont, entry}
        %{"kind" => "exit"}, nil -> {:cont, nil}
        %{"kind" => "exit"} = exit, entry -> {:cont, {entry, exit}, nil}
        %{"kind" => "entry"} = entry, open -> {:cont, {open, nil}, entry}
      end,
      fn
        nil -> {:cont, nil}
        open -> {:cont, {open, nil}, nil}
      end
    )
    |> Enum.with_index()
    |> Enum.flat_map(fn {{entry, exit}, id} ->
      entry_at = datetime(entry["time"])

      case Map.fetch(index, entry_at) do
        {:ok, entry_index} -> [trade(id, entry, entry_index, entry_at, exit, index)]
        :error -> []
      end
    end)
  end

  defp trade(id, entry, entry_index, entry_at, exit, index) do
    exit_at = exit && datetime(exit["time"])

    %{
      id: id,
      direction: entry["direction"],
      entry_index: entry_index,
      entry_at: entry_at,
      entry_price: entry["price"],
      exit_index: exit_at && Map.get(index, exit_at),
      exit_at: exit_at,
      exit_price: exit && exit["price"],
      reason: exit && exit["reason"],
      return: exit && gain(entry["direction"], entry["price"], exit["price"])
    }
  end

  defp gain(_direction, entry, _exit) when not is_number(entry) or entry == 0, do: nil
  defp gain("short", entry, exit), do: 1 - exit / entry
  defp gain(_long, entry, exit), do: exit / entry - 1

  defp markers(%{direction: direction} = t) do
    {open, close} = if direction == "short", do: {:sell, :buy}, else: {:buy, :sell}

    [%{index: t.entry_index, kind: open, price: t.entry_price, trade: t.id}] ++
      if t.exit_index,
        do: [%{index: t.exit_index, kind: close, price: t.exit_price, trade: t.id}],
        else: []
  end

  defp lanes(bars, definition, granularity) do
    roles = [
      {["entry", "long"], :buy},
      {["entry", "short"], :sell},
      {["exit", "long"], :sell},
      {["exit", "short"], :buy}
    ]

    roles
    |> Enum.flat_map(fn {path, role} ->
      definition |> get_in(path) |> StrategyWords.refs() |> Enum.map(&{&1, role})
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {ref, role} ->
      %{
        ref: ref,
        label: StrategyWords.phrase(definition, ref, granularity),
        role: role,
        runs: runs(Enum.map(bars, &(get_in(&1, ["ports", ref]) == true)))
      }
    end)
  end

  @doc "The `{from, to}` index ranges where `flags` is true, inclusive."
  @spec runs([boolean()]) :: [{non_neg_integer(), non_neg_integer()}]
  def runs(flags) do
    flags
    |> Enum.with_index()
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      [{true, from} | _] = run -> [{from, from + length(run) - 1}]
      _ -> []
    end)
  end
end
