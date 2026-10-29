defmodule OpusWeb.ResultCharts do
  @moduledoc """
  Two views of a strategy's whole test history, kept small:

  - `vs_holding/1`: its running return against just holding the instrument
    over the same years, and its drawdown, with one sentence that says
    what the chart shows (`Opus.Trading.Strategies.report/4`).
  - `fragility_grid/1`: the strategy re-run at nearby settings, coloured by
    whether each passes the backtest standard, with a verdict in words
    (`Opus.Trading.Fragility`).
  """
  use Phoenix.Component

  import OpusWeb.Format

  @width 600
  @height 150
  @dd_height 34

  attr :report, :map, required: true, doc: "Strategies.report/4"
  attr :instrument, :string, required: true

  def vs_holding(assigns) do
    assigns = assign(assigns, layout(assigns.report.points))

    ~H"""
    <div class="flex flex-col gap-2">
      <p class="m-0 text-[14px]">{headline(@report.summary, @instrument)}</p>
      <svg
        role="img"
        aria-label={"The strategy's running return against just holding #{@instrument}"}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="block h-[150px] w-full"
      >
        <line
          x1="0"
          x2={@width}
          y1={@zero}
          y2={@zero}
          stroke="var(--color-base-300)"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          points={@hold}
          fill="none"
          stroke="var(--color-neutral-content)"
          stroke-width="1.5"
          stroke-dasharray="5 4"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          points={@strategy}
          fill="none"
          stroke="var(--color-primary)"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <div class="flex flex-wrap justify-between gap-x-4 gap-y-1 text-[12px] text-muted">
        <span class="flex flex-wrap gap-x-4">
          <span class="inline-flex items-center gap-1.5">
            <span aria-hidden="true" class="inline-block h-0.5 w-4 bg-primary"></span>
            Strategy {signed_pct(@report.summary.strategy_return, 0)}
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span
              aria-hidden="true"
              class="inline-block w-4 border-t border-dashed border-neutral-content"
            ></span>
            Just holding {signed_pct(@report.summary.hold_return, 0)}
          </span>
        </span>
        <span>{date(@report.summary.from)} – {date(@report.summary.to)}</span>
      </div>
      <svg
        role="img"
        aria-label="How far the strategy fell from its best, over the same years"
        viewBox={"0 0 #{@width} #{@dd_height}"}
        preserveAspectRatio="none"
        class="block h-[34px] w-full"
      >
        <polygon points={@drawdown} fill="var(--color-error)" fill-opacity="0.45" />
      </svg>
      <p class="m-0 text-[12px] text-muted">
        Red: how far the strategy was below its best. Worst drop {pct(
          @report.summary.strategy_max_drawdown,
          1
        )}; holding's was {pct(@report.summary.hold_max_drawdown, 1)}.
        Both are as if the whole account were in the trade, over the history the backtest uses.
      </p>
    </div>
    """
  end

  defp headline(s, instrument) do
    traded =
      "It made #{signed_pct(s.strategy_return, 1)} over #{s.num_trades} trades, " <>
        "in a trade #{pct(s.time_in_market, 0)} of the time."

    held = "Just holding #{instrument} made #{signed_pct(s.hold_return, 1)}"

    comparison =
      if s.strategy_return > s.hold_return,
        do: "#{held}, so the strategy beat it.",
        else: "#{held}, so holding did better on return."

    traded <> " " <> comparison
  end

  defp layout([]),
    do: %{
      width: @width,
      height: @height,
      dd_height: @dd_height,
      zero: 0,
      hold: "",
      strategy: "",
      drawdown: ""
    }

  defp layout(points) do
    values = Enum.flat_map(points, &[&1.strategy, &1.hold]) ++ [0.0]
    {lo, hi} = Enum.min_max(values)
    span = if hi == lo, do: 1.0, else: hi - lo
    n = max(length(points) - 1, 1)
    x = fn i -> Float.round(i / n * @width, 1) end
    y = fn v -> Float.round(6 + (hi - v) / span * (@height - 12), 1) end

    worst = points |> Enum.map(& &1.drawdown) |> Enum.min(fn -> 0.0 end)
    dd_span = if worst == 0, do: 1.0, else: abs(worst)
    dy = fn v -> Float.round(abs(v) / dd_span * (@dd_height - 2), 1) end

    line = fn key ->
      points
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {p, i} -> "#{x.(i)},#{y.(Map.get(p, key))}" end)
    end

    %{
      width: @width,
      height: @height,
      dd_height: @dd_height,
      zero: y.(0.0),
      hold: line.(:hold),
      strategy: line.(:strategy),
      drawdown:
        "0,0 " <>
          (points
           |> Enum.with_index()
           |> Enum.map_join(" ", fn {p, i} -> "#{x.(i)},#{dy.(p.drawdown)}" end)) <>
          " #{@width},0"
    }
  end

  attr :grid, :map, required: true, doc: "Fragility.shape/3"
  attr :x_label, :string, required: true
  attr :y_label, :string, default: nil

  def fragility_grid(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <p class={["m-0 text-[14px] font-medium", tone_class(@grid.verdict.tone)]}>
        {@grid.verdict.words}
      </p>
      <div class="overflow-x-auto">
        <table class="border-separate border-spacing-1 text-[12px]">
          <caption class="pb-1 text-left text-muted">
            Across: {@x_label}<span :if={@y_label}> · Down: {@y_label}</span>
          </caption>
          <thead>
            <tr>
              <th :if={@y_label} scope="col"></th>
              <th :for={x <- @grid.xs} scope="col" class="px-1 font-normal text-muted">
                {value(x)}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @grid.rows}>
              <th :if={@y_label} scope="row" class="pr-1 text-right font-normal text-muted">
                {value(row.y)}
              </th>
              <td
                :for={c <- row.cells}
                title={cell_title(c, @x_label, @y_label)}
                class={[
                  "h-10 min-w-12 rounded-field px-1.5 text-center tabular-nums",
                  cell_class(c),
                  c.current && "outline outline-2 outline-offset-1 outline-base-content"
                ]}
              >
                {if c.error, do: "—", else: signed_pct(c.total_return, 0)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="m-0 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted">
        <span><span aria-hidden="true" class="mr-1 inline-block size-2.5 rounded-sm bg-success/70"></span>passes the standard</span>
        <span><span aria-hidden="true" class="mr-1 inline-block size-2.5 rounded-sm bg-success/20"></span>made money, didn't pass</span>
        <span><span aria-hidden="true" class="mr-1 inline-block size-2.5 rounded-sm bg-error/40"></span>lost money</span>
        <span>outlined: the current settings</span>
      </p>
    </div>
    """
  end

  defp cell_class(%{error: e}) when is_binary(e), do: "bg-base-300 text-muted"
  defp cell_class(%{passed: true}), do: "bg-success/70 text-success-content font-medium"
  defp cell_class(%{total_return: r}) when is_number(r) and r > 0, do: "bg-success/20"
  defp cell_class(_), do: "bg-error/40"

  defp cell_title(%{error: e} = c, x_label, y_label) when is_binary(e),
    do: "#{settings(c, x_label, y_label)}: couldn't run (#{e})"

  defp cell_title(c, x_label, y_label) do
    "#{settings(c, x_label, y_label)}: #{signed_pct(c.total_return, 1)} over #{c.num_trades} trades, " <>
      "luck test #{num(c.t_stat, 1)}, " <>
      if(c.passed, do: "passes the standard", else: "doesn't pass")
  end

  defp settings(c, x_label, nil), do: "#{x_label} #{value(c.x)}"
  defp settings(c, x_label, y_label), do: "#{x_label} #{value(c.x)}, #{y_label} #{value(c.y)}"

  defp value(v) when is_number(v) and v == trunc(v), do: Integer.to_string(trunc(v))
  defp value(v) when is_number(v), do: num(v, 2)
  defp value(_), do: ""

  defp tone_class(:sturdy), do: "text-success"
  defp tone_class(:mixed), do: "text-warning"
  defp tone_class(:none), do: "text-muted"
  defp tone_class(_fragile_or_weak), do: "text-error"
end
