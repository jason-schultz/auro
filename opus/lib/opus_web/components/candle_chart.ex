defmodule OpusWeb.CandleChart do
  @moduledoc """
  A candlestick chart drawn as inline SVG: completed candles, optional
  horizontal price lines (entry, stop, target, last price) and an optional
  moving-average overlay. Pure layout; the LiveView decides what to show.

  With `signals` (`Opus.Trading.SignalChart.shape/3`) it also draws each
  trade the rules made: the bars it was open shaded, ▲ where it bought and
  ▼ where it sold, and under the time axis one strip per rule, lit on the
  bars it was true, lined up with the candles above. `marker_event` makes a
  marker clickable (`phx-value-trade` is the trade's id); `focus` rings the
  chosen trade's opening marker.

  Prices that fall outside the candles' range are not drawn as lines. They
  get a note at the nearest edge instead, so a stop 2.6% away still reads.
  """
  use Phoenix.Component

  import OpusWeb.Format, only: [price: 1]

  @width 960
  @height 280
  @pad 8
  @axis 80
  @panel_height 70

  @line_colors [
    "var(--color-accent)",
    "var(--color-secondary)",
    "var(--color-neutral-content)"
  ]

  attr :candles, :list, required: true, doc: "oldest first: %{time, open, high, low, close}"
  attr :lines, :list, default: [], doc: "%{price, label, kind: :entry | :stop | :target | :now}"
  attr :overlay_period, :integer, default: nil, doc: "simple moving average to draw, if any"
  attr :bars, :integer, default: nil, doc: "how many of the trailing candles to show"
  attr :label, :string, required: true
  attr :signals, :map, default: nil, doc: "markers, spans and lanes from SignalChart.shape/3"
  attr :marker_event, :string, default: nil
  attr :focus, :integer, default: nil, doc: "trade id whose opening marker is ringed"

  def candle_chart(%{candles: []} = assigns) do
    ~H"""
    <p class="text-[13px] text-muted">
      No completed candles stored for this instrument and timeframe yet.
    </p>
    """
  end

  def candle_chart(assigns) do
    assigns =
      assign(
        assigns,
        layout(
          assigns.candles,
          assigns.lines,
          assigns.overlay_period,
          assigns.bars,
          assigns.signals,
          assigns.focus
        )
      )

    ~H"""
    <div class="overflow-x-auto">
      <svg
        role="img"
        aria-label={@label}
        viewBox={"0 0 #{@width} #{@height + 20}"}
        class="block h-auto w-full min-w-[640px]"
      >
        <g aria-hidden="true">
          <g :for={tick <- @ticks}>
            <line
              x1="0"
              y1={tick.y}
              x2={@plot_width}
              y2={tick.y}
              class="stroke-base-300"
              stroke-width="1"
            />
            <text x={@plot_width + 8} y={tick.y + 5} font-size="13" class="fill-neutral-content">
              {tick.text}
            </text>
          </g>
          <rect
            :for={span <- @spans}
            x={span.x}
            y="0"
            width={span.width}
            height={@height}
            fill="var(--color-info)"
            fill-opacity="0.1"
          />
          <g :for={candle <- @drawn}>
            <line
              x1={candle.x}
              y1={candle.high}
              x2={candle.x}
              y2={candle.low}
              stroke={candle.color}
              stroke-width="1"
            />
            <rect
              x={candle.x - @body / 2}
              y={candle.top}
              width={@body}
              height={candle.height}
              fill={candle.color}
            />
          </g>
          <g :for={o <- @overlays}>
            <polyline
              :for={points <- o.lines}
              points={points}
              fill="none"
              stroke={o.color}
              stroke-width="1.5"
            />
          </g>
          <polyline
            :if={@overlay}
            points={@overlay}
            fill="none"
            stroke="var(--color-accent)"
            stroke-width="1.5"
          />
          <g :for={line <- @drawn_lines}>
            <line
              x1="0"
              y1={line.y}
              x2={@plot_width}
              y2={line.y}
              stroke={line.color}
              stroke-width={line.width}
              stroke-dasharray={line.dash}
            />
            <rect
              x={@plot_width + 2}
              y={line.y - 10}
              width={@axis - 2}
              height="20"
              rx="4"
              fill={line.color}
            />
            <text
              x={@plot_width + 8}
              y={line.y + 4}
              font-size="11"
              font-weight="600"
              fill="var(--color-base-100)"
            >
              {line.text}
            </text>
          </g>
          <circle
            :if={@ring}
            cx={@ring.x}
            cy={@ring.y}
            r="11"
            fill="none"
            stroke="var(--color-base-content)"
            stroke-width="1.5"
          />
          <g :for={note <- @edge_notes}>
            <rect x="0" y={note.y} width={@plot_width} height="3" fill={note.color} />
            <text x="8" y={note.text_y} font-size="11" fill={note.color}>{note.text}</text>
          </g>
          <text x="2" y={@height + 17} font-size="13" class="fill-neutral-content">
            {@first_time}
          </text>
          <text
            x={@plot_width - 2}
            y={@height + 17}
            font-size="13"
            text-anchor="end"
            class="fill-neutral-content"
          >
            {@last_time}
          </text>
        </g>
        <g
          :for={marker <- @markers}
          phx-click={@marker_event}
          phx-value-trade={marker.trade}
          class={@marker_event && "cursor-pointer"}
        >
          <title>{marker.title}</title>
          <path d={marker.path} fill={marker.color} />
        </g>
      </svg>
      <div
        :if={@overlays != []}
        class="flex min-w-[640px] flex-wrap gap-x-4 gap-y-1 pt-1 text-[12px] text-muted"
      >
        <span :for={o <- @overlays} class="inline-flex items-center gap-1.5">
          <span aria-hidden="true" class="inline-block h-0.5 w-4" style={"background: #{o.color}"}></span>
          {o.label}
        </span>
      </div>
      <div :for={p <- @panels} class="flex min-w-[640px] flex-col gap-1 pt-3">
        <span class="text-[13px]">
          {p.label}
          <span :if={p.levels != []} class="text-muted">
            · dashed at {Enum.map_join(p.levels, ", ", &level_text(&1.value))}
          </span>
        </span>
        <svg
          role="img"
          aria-label={"#{p.label} over the same bars"}
          viewBox={"0 0 #{@width} #{p.height}"}
          preserveAspectRatio="none"
          class="block w-full"
          style={"height: #{p.height}px"}
        >
          <rect x="0" y="0" width={@plot_width} height={p.height} rx="3" class="fill-base-100" />
          <line
            :for={l <- p.levels}
            x1="0"
            y1={l.y}
            x2={@plot_width}
            y2={l.y}
            stroke="var(--color-neutral-content)"
            stroke-opacity="0.6"
            stroke-dasharray="4 4"
            vector-effect="non-scaling-stroke"
          />
          <polyline
            :for={points <- p.also}
            points={points}
            fill="none"
            stroke="var(--color-secondary)"
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
          />
          <polyline
            :for={points <- p.lines}
            points={points}
            fill="none"
            stroke="var(--color-accent)"
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
          />
        </svg>
      </div>
      <div :if={@lanes != []} class="flex min-w-[640px] flex-col gap-2.5 pt-3">
        <div :for={lane <- @lanes} class="flex flex-col gap-1">
          <span class="text-[13px] leading-snug">{lane.label}</span>
          <svg
            aria-hidden="true"
            viewBox={"0 0 #{@width} 8"}
            preserveAspectRatio="none"
            class="block h-2 w-full"
          >
            <rect x="0" y="0" width={@plot_width} height="8" rx="2" class="fill-base-100" />
            <rect
              :for={run <- lane.runs}
              x={run.x}
              y="0"
              width={run.width}
              height="8"
              fill={lane.color}
            />
          </svg>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  @spec layout([map()], [map()], integer() | nil, integer() | nil, map() | nil, integer() | nil) ::
          map()
  def layout(candles, lines, overlay_period, bars, signals \\ nil, focus \\ nil) do
    shown = if bars, do: Enum.take(candles, -bars), else: candles
    n = length(shown)
    plot_width = @width - @axis
    step = plot_width / n
    body = max(2.0, step * 0.55)

    {low, high} =
      shown
      |> Enum.flat_map(&[&1.low, &1.high])
      |> Kernel.++(overlay_values(signals, length(candles) - n))
      |> Enum.min_max()

    span = max(high - low, high * 0.001)
    lo = low - span * 0.04
    hi = high + span * 0.04
    y = fn p -> Float.round(@pad + (hi - p) / (hi - lo) * (@height - 2 * @pad), 1) end
    x = fn i -> Float.round(i * step + step / 2, 1) end

    drawn =
      shown
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        top = y.(max(c.open, c.close))
        bottom = y.(min(c.open, c.close))

        %{
          x: x.(i),
          high: y.(c.high),
          low: y.(c.low),
          top: top,
          height: max(1.5, Float.round(bottom - top, 1)),
          color: if(c.close >= c.open, do: "var(--color-success)", else: "var(--color-error)")
        }
      end)

    {drawn_lines, edge_notes} =
      lines
      |> Enum.reject(&is_nil(&1.price))
      |> Enum.split_with(&(&1.price >= lo and &1.price <= hi))

    %{
      width: @width,
      height: @height,
      axis: @axis,
      plot_width: plot_width,
      body: Float.round(body, 1),
      drawn: drawn,
      ticks: ticks(lo, hi, y),
      overlay: overlay(candles, shown, overlay_period, x, y),
      drawn_lines:
        Enum.map(drawn_lines, fn line ->
          Map.merge(style(line.kind), %{y: y.(line.price), text: price(line.price)})
        end),
      edge_notes:
        Enum.map(edge_notes, fn line ->
          above = line.price > hi
          pct = Float.round(abs(line.price / List.last(shown).close - 1) * 100, 1)

          %{
            color: style(line.kind).color,
            y: if(above, do: 0, else: @height - 3),
            text_y: if(above, do: 16, else: @height - 8),
            text:
              "#{line.label} #{price(line.price)} is #{pct}% #{if above, do: "above", else: "below"}, off this chart"
          }
        end),
      first_time: stamp(List.first(shown).time),
      last_time: stamp(List.last(shown).time)
    }
    |> Map.merge(signal_layout(signals, length(candles) - n, shown, step, x, y, focus))
  end

  defp signal_layout(nil, _offset, _shown, _step, _x, _y, _focus),
    do: %{markers: [], spans: [], lanes: [], ring: nil, overlays: [], panels: []}

  defp signal_layout(signals, offset, shown, step, x, y, focus) do
    n = length(shown)
    seen? = &(&1 >= 0 and &1 < n)
    at = fn i -> Enum.at(shown, i) end

    markers =
      for m <- signals.markers, i = m.index - offset, seen?.(i) do
        candle = at.(i)
        cx = x.(i)

        {path, color} =
          case m.kind do
            :buy ->
              cy = y.(candle.low) + 12

              {"M#{cx} #{cy - 6} L#{cx + 6} #{cy + 5} L#{cx - 6} #{cy + 5} Z",
               "var(--color-info)"}

            :sell ->
              cy = y.(candle.high) - 12

              {"M#{cx} #{cy + 6} L#{cx + 6} #{cy - 5} L#{cx - 6} #{cy - 5} Z",
               "var(--color-warning)"}
          end

        %{
          path: path,
          color: color,
          trade: m.trade,
          kind: m.kind,
          x: cx,
          y: if(m.kind == :buy, do: y.(candle.low) + 12, else: y.(candle.high) - 12),
          title: "#{if m.kind == :buy, do: "Buy", else: "Sell"} at #{price(m.price)}"
        }
      end

    ring =
      Enum.find_value(signals.markers, fn m ->
        m.trade == focus && Enum.find(markers, &(&1.trade == m.trade))
      end)

    spans =
      for {from, to} <- signals.spans,
          from = max(from - offset, 0),
          to = min(to - offset, n - 1),
          from <= to do
        %{x: Float.round(from * step, 1), width: Float.round((to - from + 1) * step, 1)}
      end

    lanes =
      signals.lanes
      |> Enum.map(fn lane ->
        %{
          label: lane.label,
          color: if(lane.role == :buy, do: "var(--color-info)", else: "var(--color-warning)"),
          runs:
            for {from, to} <- lane.runs,
                from = max(from - offset, 0),
                to = min(to - offset, n - 1),
                from <= to do
              %{
                x: Float.round(from * step, 1),
                width: Float.round(max(to - from + 1, 1) * step, 1)
              }
            end
        }
      end)

    overlays =
      signals
      |> Map.get(:overlays, [])
      |> Enum.with_index()
      |> Enum.map(fn {o, k} ->
        %{
          label: o.label,
          color: Enum.at(@line_colors, rem(k, length(@line_colors))),
          lines: o.values |> Enum.drop(offset) |> Enum.take(n) |> polylines(x, y)
        }
      end)

    %{
      markers: markers,
      spans: spans,
      lanes: lanes,
      ring: ring && %{x: ring.x, y: ring.y},
      overlays: overlays,
      panels: signals |> Map.get(:panels, []) |> Enum.map(&panel(&1, offset, n, x))
    }
  end

  # Indicator lines drawn on the candles widen the price scale so they
  # aren't cut off.
  defp overlay_values(nil, _offset), do: []

  defp overlay_values(%{overlays: overlays}, offset),
    do: for(o <- overlays, v <- Enum.drop(o.values, offset), is_number(v), do: v)

  defp overlay_values(_signals, _offset), do: []

  # A line through the values that exist; a gap where a value is missing.
  defp polylines(values, x, y) do
    values
    |> Enum.with_index()
    |> Enum.chunk_by(fn {v, _i} -> is_number(v) end)
    |> Enum.filter(fn [{v, _} | _] -> is_number(v) end)
    |> Enum.map(fn run -> Enum.map_join(run, " ", fn {v, i} -> "#{x.(i)},#{y.(v)}" end) end)
  end

  # An indicator in its own small chart: its scale is its fixed range, or
  # the spread of its values and reference levels.
  defp panel(p, offset, n, x) do
    values = p.values |> Enum.drop(offset) |> Enum.take(n)
    also = if p.also, do: p.also |> Enum.drop(offset) |> Enum.take(n)

    {lo, hi} =
      case p.range do
        {lo, hi} ->
          {lo, hi}

        nil ->
          (values ++ (also || []) ++ p.levels)
          |> Enum.filter(&is_number/1)
          |> Enum.min_max(fn -> {0.0, 1.0} end)
      end

    span = if hi == lo, do: 1.0, else: hi - lo
    y = fn v -> Float.round(4 + (hi - v) / span * (@panel_height - 8), 1) end

    %{
      label: p.label,
      lines: polylines(values, x, y),
      also: if(also, do: polylines(also, x, y), else: []),
      levels: Enum.map(p.levels, &%{y: y.(&1), value: &1}),
      height: @panel_height
    }
  end

  defp level_text(v) when v == trunc(v), do: Integer.to_string(trunc(v))
  defp level_text(v), do: :erlang.float_to_binary(v, decimals: 1)

  defp style(:entry), do: %{color: "var(--color-neutral-content)", width: 1, dash: "5 4"}
  defp style(:stop), do: %{color: "var(--color-error)", width: 1.5, dash: "none"}
  defp style(:target), do: %{color: "var(--color-success)", width: 1.5, dash: "none"}
  defp style(:now), do: %{color: "var(--color-primary)", width: 1.5, dash: "none"}

  defp ticks(lo, hi, y) do
    for q <- [0.1, 0.5, 0.9] do
      p = lo + (hi - lo) * q
      %{y: y.(p), text: price(p)}
    end
  end

  defp overlay(_all, _shown, nil, _x, _y), do: nil

  defp overlay(all, shown, period, x, y) do
    closes = Enum.map(all, & &1.close)
    offset = length(all) - length(shown)

    points =
      shown
      |> Enum.with_index()
      |> Enum.flat_map(fn {_c, i} ->
        upto = offset + i + 1

        if upto >= period do
          window = closes |> Enum.slice((upto - period)..(upto - 1))
          [~s(#{x.(i)},#{y.(Enum.sum(window) / period)})]
        else
          []
        end
      end)

    if points == [], do: nil, else: Enum.join(points, " ")
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d %H:%M")
  defp stamp(_), do: ""
end
