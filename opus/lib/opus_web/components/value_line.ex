defmodule OpusWeb.Components.ValueLine do
  @moduledoc """
  One value over time as a line (net worth, an account, the holdings): a
  single series, so no legend; its title names it. The low and high are
  labelled on a recessive axis, each day has a hover target wider than the
  line with its date and value, and a table view sits underneath for anyone
  who'd rather read numbers.
  """
  use Phoenix.Component

  import OpusWeb.Format, only: [day: 1, money: 1, signed_money: 1]

  @width 600
  @height 160

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "[%{on: Date.t(), value: number()}], oldest first"
  attr :label, :string, required: true, doc: "what the line is, for screen readers and the table"

  attr :empty, :string,
    default: "Nothing recorded yet.",
    doc: "what to say with fewer than two points"

  def value_line(%{points: [_, _ | _]} = assigns) do
    assigns = assign(assigns, layout(assigns.points))

    ~H"""
    <figure id={@id} class="m-0 flex flex-col gap-1.5">
      <div class="flex gap-2">
        <div class="flex w-20 shrink-0 flex-col justify-between text-right text-[11px] text-muted tabular-nums">
          <span>{money(@hi)}</span>
          <span>{money(@lo)}</span>
        </div>
        <svg
          role="img"
          aria-label={"#{@label}, #{day(@first.on)} to #{day(@last.on)}"}
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          class="block h-[160px] w-full"
        >
          <line
            :for={y <- [6, @height - 6]}
            x1="0"
            x2={@width}
            y1={y}
            y2={y}
            stroke="var(--color-base-300)"
            vector-effect="non-scaling-stroke"
          />
          <polyline
            points={@line}
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
            vector-effect="non-scaling-stroke"
          />
          <rect
            :for={{p, x, w} <- @targets}
            x={x}
            y="0"
            width={w}
            height={@height}
            fill="transparent"
            class="hover:fill-base-content/5"
          >
            <title>{day(p.on)}: {money(p.value)}</title>
          </rect>
        </svg>
      </div>
      <figcaption class="flex justify-between pl-22 text-[12px] text-muted">
        <span>{day(@first.on)}</span>
        <span>
          {day(@last.on)}: {money(@last.value)} ({signed_money(@last.value - @first.value)} over the line)
        </span>
      </figcaption>
      <details class="text-[12px] text-muted">
        <summary class="cursor-pointer">As a table</summary>
        <table class="mt-1 w-full max-w-sm border-collapse">
          <thead>
            <tr>
              <th class="text-left font-medium">Close</th>
              <th class="text-right font-medium">{@label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- Enum.reverse(@points)}>
              <td>{day(p.on)}</td>
              <td class="text-right tabular-nums">{money(p.value)}</td>
            </tr>
          </tbody>
        </table>
      </details>
    </figure>
    """
  end

  def value_line(assigns) do
    ~H"""
    <p id={@id} class="m-0 text-[13px] text-muted">{@empty}</p>
    """
  end

  defp layout(points) do
    {lo, hi} = points |> Enum.map(& &1.value) |> Enum.min_max()
    span = if hi == lo, do: 1.0, else: hi - lo
    n = length(points) - 1
    x = fn i -> i / n * @width end
    y = fn v -> 6 + (hi - v) / span * (@height - 12) end
    step = @width / n

    %{
      width: @width,
      height: @height,
      lo: lo,
      hi: hi,
      first: List.first(points),
      last: List.last(points),
      line:
        points
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {p, i} ->
          "#{Float.round(x.(i), 1)},#{Float.round(y.(p.value), 1)}"
        end),
      # Each day's hover target spans half the way to its neighbours.
      targets:
        points
        |> Enum.with_index()
        |> Enum.map(fn {p, i} ->
          left = max(x.(i) - step / 2, 0.0)
          right = min(x.(i) + step / 2, @width / 1)
          {p, Float.round(left, 1), Float.round(right - left, 1)}
        end)
    }
  end
end
