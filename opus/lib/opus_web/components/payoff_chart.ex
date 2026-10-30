defmodule OpusWeb.PayoffChart do
  @moduledoc """
  The payoff chart for one option position: P&L against the underlying's
  price at expiry (the hockey stick), halfway there and today, with the
  strike, every breakeven and spot marked and the expected one-standard-deviation
  move shaded. Drawn from the curves the engine's scenario analysis returns.
  """
  use Phoenix.Component

  import OpusWeb.Format, only: [money: 1, price: 1]

  @pad_x 8
  @pad_y 14

  # Desktop draws the engine's full ±25% grid; the phone version keeps the
  # strike's neighbourhood (±12%) so the hockey stick fits the screen, with
  # larger type because the drawing is scaled down harder.
  @desktop %{width: 960, height: 320, axis: 90, font: 11, window: nil, min_width: "min-w-[640px]"}
  @compact %{width: 480, height: 300, axis: 76, font: 13, window: 0.12, min_width: ""}

  attr :analysis, :map, required: true
  attr :compact, :boolean, default: false
  attr :class, :string, default: ""

  def payoff_chart(%{analysis: %{"curves" => [_ | _]}} = assigns) do
    assigns =
      assign(assigns, layout(assigns.analysis, if(assigns.compact, do: @compact, else: @desktop)))

    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <svg
        role="img"
        aria-label={@label}
        viewBox={"0 0 #{@width} #{@height + 22}"}
        class={["block h-auto w-full", @min_width]}
      >
        <g aria-hidden="true">
          <rect
            :if={@band}
            x={@band.x1}
            y="0"
            width={@band.x2 - @band.x1}
            height={@height}
            fill="var(--color-primary)"
            fill-opacity="0.08"
          />
          <g :for={tick <- @y_ticks}>
            <line
              x1="0"
              y1={tick.y}
              x2={@plot_width}
              y2={tick.y}
              class="stroke-base-300"
              stroke-width="1"
            />
            <text x={@plot_width + 8} y={tick.y + 4} font-size={@font} class="fill-neutral-content">
              {tick.text}
            </text>
          </g>
          <line
            x1="0"
            y1={@zero_y}
            x2={@plot_width}
            y2={@zero_y}
            class="stroke-neutral-content"
            stroke-width="1"
          />
          <g :for={marker <- @markers}>
            <line
              x1={marker.x}
              y1="0"
              x2={marker.x}
              y2={@height}
              stroke={marker.color}
              stroke-width="1"
              stroke-dasharray="3 4"
            />
            <text x={marker.x + 4} y={marker.text_y} font-size={@font} fill={marker.color}>
              {marker.text}
            </text>
          </g>
          <polyline
            :for={curve <- @curves}
            points={curve.points}
            fill="none"
            stroke={curve.color}
            stroke-width={curve.width}
            stroke-dasharray={curve.dash}
          />
          <text x="2" y={@height + 18} font-size={@font} class="fill-neutral-content">{@x_min}</text>
          <text
            x={@plot_width - 2}
            y={@height + 18}
            font-size={@font}
            text-anchor="end"
            class="fill-neutral-content"
          >
            {@x_max}
          </text>
        </g>
      </svg>
      <div class="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-[13px] text-muted">
        <span :for={curve <- @curves} class="inline-flex items-center gap-2">
          <span
            aria-hidden="true"
            class="inline-block w-5 border-t-2"
            style={"border-color: #{curve.color}; border-style: #{curve.legend_style}"}
          ></span>
          {curve.label}
        </span>
        <span :if={@band} class="inline-flex items-center gap-2">
          <span aria-hidden="true" class="inline-block size-3 rounded-sm bg-primary/20"></span>
          expected one-sigma move
        </span>
      </div>
    </div>
    """
  end

  def payoff_chart(assigns) do
    ~H"""
    <p class={["text-[13px] text-muted", @class]}>
      No payoff curve: the engine returned no price grid.
    </p>
    """
  end

  @doc false
  @spec layout(map(), map()) :: map()
  def layout(%{"curves" => curves} = analysis, size \\ @desktop) do
    spot = analysis["spot"]
    expected = analysis["expected_move"]

    curves =
      Enum.map(curves, &Map.update!(&1, "points", fn pts -> window(pts, spot, size.window) end))

    points = Enum.flat_map(curves, & &1["points"])
    {x_lo, x_hi} = points |> Enum.map(& &1["price"]) |> Enum.min_max()
    {y_lo, y_hi} = points |> Enum.map(& &1["pnl"]) |> Enum.min_max()
    y_lo = min(y_lo, 0.0)
    y_hi = max(y_hi, 0.0)
    y_span = max(y_hi - y_lo, 1.0)
    plot_width = size.width - size.axis

    x = fn p ->
      Float.round(@pad_x + (p - x_lo) / max(x_hi - x_lo, 1.0e-9) * (plot_width - 2 * @pad_x), 1)
    end

    y = fn v -> Float.round(@pad_y + (y_hi - v) / y_span * (size.height - 2 * @pad_y), 1) end

    %{
      width: size.width,
      height: size.height,
      font: size.font,
      min_width: size.min_width,
      plot_width: plot_width,
      zero_y: y.(0.0),
      label: "Profit and loss by underlying price for #{strategy_label(analysis["strategy"])}",
      curves:
        curves
        |> Enum.map(fn curve ->
          Map.merge(style(curve["label"], curve["days_to_expiry"]), %{
            points: Enum.map_join(curve["points"], " ", &"#{x.(&1["price"])},#{y.(&1["pnl"])}")
          })
        end)
        |> Enum.reverse(),
      y_ticks:
        for(q <- [0.08, 0.5, 0.92], v = y_hi - y_span * q, do: %{y: y.(v), text: money(v)}),
      markers:
        Enum.concat([
          [{analysis["strike"], "Strike", "var(--color-accent)", size.font + 3}],
          # Every break-even a structure has (an iron condor has two), on
          # one row; a single leg sends only `breakeven`.
          for(
            b <- breakevens(analysis),
            do: {b, "Breakeven", "var(--color-neutral-content)", 2 * size.font + 8}
          ),
          [{spot, "Now", "var(--color-primary)", 3 * size.font + 13}]
        ])
        |> Enum.reject(fn {p, _, _, _} -> is_nil(p) or p < x_lo or p > x_hi end)
        |> Enum.map(fn {p, name, color, text_y} ->
          %{x: x.(p), color: color, text_y: text_y, text: "#{name} #{price(p)}"}
        end),
      band:
        if is_number(spot) and is_number(expected) and expected > 0 do
          %{x1: x.(max(spot - expected, x_lo)), x2: x.(min(spot + expected, x_hi))}
        end,
      x_min: price(x_lo),
      x_max: price(x_hi)
    }
  end

  defp breakevens(%{"breakevens" => [_ | _] = breakevens}), do: breakevens
  defp breakevens(analysis), do: [analysis["breakeven"]]

  # Keep only the points within ±window of the spot (all of them when nil).
  defp window(points, _spot, nil), do: points

  defp window(points, spot, window) when is_number(spot) do
    kept = Enum.filter(points, &(abs(&1["price"] / spot - 1) <= window + 1.0e-9))
    if length(kept) >= 5, do: kept, else: points
  end

  defp window(points, _spot, _window), do: points

  defp style("expiry", _days),
    do: %{
      label: "At expiry",
      color: "var(--color-base-content)",
      width: 2,
      dash: "none",
      legend_style: "solid"
    }

  defp style("today", days),
    do: %{
      label: "Today, #{round(days)} days left",
      color: "var(--color-primary)",
      width: 1.5,
      dash: "2 4",
      legend_style: "dotted"
    }

  defp style(_other, days),
    do: %{
      label: "Halfway, #{round(days)} days left",
      color: "var(--color-secondary)",
      width: 1.5,
      dash: "6 4",
      legend_style: "dashed"
    }

  defp strategy_label("cash_secured_put"), do: "a cash-secured put"
  defp strategy_label("covered_call"), do: "a covered call"
  defp strategy_label("long_call"), do: "a long call"
  defp strategy_label("long_put"), do: "a long put"
  defp strategy_label("structure"), do: "the whole multi-leg trade"
  defp strategy_label(other), do: to_string(other)
end
