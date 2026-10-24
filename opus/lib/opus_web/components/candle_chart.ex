defmodule OpusWeb.CandleChart do
  @moduledoc """
  A candlestick chart drawn as inline SVG: completed candles, optional
  horizontal price lines (entry, stop, target, last price) and an optional
  moving-average overlay. Pure layout; the LiveView decides what to show.

  Prices that fall outside the candles' range are not drawn as lines. They
  get a note at the nearest edge instead, so a stop 2.6% away still reads.
  """
  use Phoenix.Component

  import OpusWeb.Format, only: [price: 1]

  @width 960
  @height 280
  @pad 8
  @axis 80

  attr :candles, :list, required: true, doc: "oldest first: %{time, open, high, low, close}"
  attr :lines, :list, default: [], doc: "%{price, label, kind: :entry | :stop | :target | :now}"
  attr :overlay_period, :integer, default: nil, doc: "simple moving average to draw, if any"
  attr :bars, :integer, default: nil, doc: "how many of the trailing candles to show"
  attr :label, :string, required: true

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
        layout(assigns.candles, assigns.lines, assigns.overlay_period, assigns.bars)
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
            <text x={@plot_width + 8} y={tick.y + 4} font-size="11" class="fill-neutral-content">
              {tick.text}
            </text>
          </g>
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
          <g :for={note <- @edge_notes}>
            <rect x="0" y={note.y} width={@plot_width} height="3" fill={note.color} />
            <text x="8" y={note.text_y} font-size="11" fill={note.color}>{note.text}</text>
          </g>
          <text x="2" y={@height + 16} font-size="11" class="fill-neutral-content">
            {@first_time}
          </text>
          <text
            x={@plot_width - 2}
            y={@height + 16}
            font-size="11"
            text-anchor="end"
            class="fill-neutral-content"
          >
            {@last_time}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  @doc false
  @spec layout([map()], [map()], integer() | nil, integer() | nil) :: map()
  def layout(candles, lines, overlay_period, bars) do
    shown = if bars, do: Enum.take(candles, -bars), else: candles
    n = length(shown)
    plot_width = @width - @axis
    step = plot_width / n
    body = max(2.0, step * 0.55)

    {low, high} =
      Enum.reduce(shown, {nil, nil}, fn c, {lo, hi} ->
        {min_nil(lo, c.low), max_nil(hi, c.high)}
      end)

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
  end

  defp min_nil(nil, v), do: v
  defp min_nil(a, b), do: min(a, b)
  defp max_nil(nil, v), do: v
  defp max_nil(a, b), do: max(a, b)

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
