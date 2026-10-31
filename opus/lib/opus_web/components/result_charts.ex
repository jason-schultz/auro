defmodule OpusWeb.ResultCharts do
  @moduledoc """
  Two views of a strategy's whole test history, kept small:

  - `vs_holding/1`: its account against just holding the instrument over
    the same years, measured the same way: holding at the strategy's risk
    on the chart, each year side by side, and a few sentences on return for
    the risk and how the two move together
    (`Opus.Trading.Strategies.report/4`).
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

  @doc """
  The strategy's account against just holding, like for like: holding at
  the strategy's risk on the chart (holding in full swings so much more
  that it says little on its own), each year side by side, and a few
  sentences on return for the risk taken and how the two move together.
  """
  def vs_holding(assigns) do
    assigns = assign(assigns, layout(assigns.report.points))

    ~H"""
    <div class="flex flex-col gap-2">
      <p :for={line <- headline(@report.summary, @instrument)} class="m-0 text-[14px]">{line}</p>
      <svg
        role="img"
        aria-label={"The strategy's account against holding #{@instrument} at the same risk"}
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
          points={@matched}
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
            Holding at the same risk {signed_pct(@report.summary.matched_return, 0)}
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
        Red: how far the account was below its best. Worst drop {pct(
          @report.summary.strategy_max_drawdown,
          1
        )}; holding at the same risk {pct(@report.summary.matched_max_drawdown, 1)}, holding in full {pct(
          @report.summary.hold_max_drawdown,
          1
        )}. The account risks {pct(@report.summary.risk_pct, 1)} a trade, as live sizes it; over the history the backtest uses.
      </p>
      <table class="mt-1 w-full border-collapse text-[13px] tabular-nums">
        <caption class="sr-only">Each year: the strategy, holding at the same risk, holding</caption>
        <thead class="text-[12px] text-muted">
          <tr>
            <th scope="col" class="py-1 text-left font-normal">Year</th>
            <th scope="col" class="py-1 text-right font-normal">Strategy</th>
            <th scope="col" class="py-1 text-right font-normal">Holding, same risk</th>
            <th scope="col" class="py-1 text-right font-normal">Holding</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={y <- @report.years}>
            <th scope="row" class="py-0.5 text-left font-normal">{y.year}</th>
            <td class={["py-0.5 text-right", tone(y.strategy)]}>{signed_pct(y.strategy, 1)}</td>
            <td class="py-0.5 text-right text-muted">{signed_pct(y.matched, 1)}</td>
            <td class="py-0.5 text-right text-muted">{signed_pct(y.hold, 1)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # What the card says, in order: what the account did, what holding did
  # and at what risk, which did better for the risk, and how they move
  # together.
  defp headline(s, instrument) do
    [
      "The account made #{signed_pct(s.strategy_return, 1)} over #{s.num_trades} trades, " <>
        "in a trade #{pct(s.time_in_market, 0)} of the time. Just holding #{instrument} " <>
        "made #{signed_pct(s.hold_return, 0)}, but swings far more.",
      "Kept small enough to swing as much as the strategy (#{pct(s.risk_scale, 0)} of the " <>
        "money in it), holding made #{signed_pct(s.matched_return, 1)}: " <>
        verdict(s),
      together(s.correlation, instrument)
    ]
  end

  defp verdict(%{strategy_return: mine, matched_return: held} = s) when mine > held,
    do: "for the risk taken, the strategy did better (Sharpe #{sharpe(s)})."

  defp verdict(s),
    do: "for the risk taken, holding did as well or better (Sharpe #{sharpe(s)})."

  defp sharpe(s), do: "#{num(s.strategy_annual_sharpe)} against #{num(s.hold_annual_sharpe)}"

  defp together(nil, _instrument), do: "Too few days to say how the two move together."

  defp together(c, instrument) when abs(c) < 0.2,
    do:
      "Its days barely follow #{instrument}'s (correlation #{num(c)}), so it adds something " <>
        "holding doesn't have."

  defp together(c, instrument) when c > 0,
    do:
      "Its days tend to follow #{instrument}'s (correlation #{num(c)}): part of what it " <>
        "makes is the market's rise."

  defp together(c, instrument),
    do: "Its days tend to go against #{instrument}'s (correlation #{num(c)})."

  defp layout([]),
    do: %{
      width: @width,
      height: @height,
      dd_height: @dd_height,
      zero: 0,
      matched: "",
      strategy: "",
      drawdown: ""
    }

  defp layout(points) do
    values = Enum.flat_map(points, &[&1.strategy, &1.matched]) ++ [0.0]
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
      matched: line.(:matched),
      strategy: line.(:strategy),
      drawdown:
        "0,0 " <>
          (points
           |> Enum.with_index()
           |> Enum.map_join(" ", fn {p, i} -> "#{x.(i)},#{dy.(p.drawdown)}" end)) <>
          " #{@width},0"
    }
  end

  attr :with_rules, :map, default: nil, doc: "Together.run/1 outcome, or nil without limits"
  attr :without_rules, :map, required: true, doc: "Together.run/1 outcome"
  attr :from, :any, required: true
  attr :to, :any, required: true
  attr :label, :string, default: "Together", doc: "legend for the line without safety rules"

  @doc """
  Several strategies on one account: its running return with the safety
  rules (solid) and without them (dashed), on one time axis, and how far it
  fell from its best with the rules.
  """
  def account_curve(assigns) do
    main = assigns.with_rules || assigns.without_rules
    series = Enum.reject([assigns.with_rules, assigns.without_rules], &is_nil/1)
    values = series |> Enum.flat_map(& &1.points) |> Enum.map(& &1.equity)
    {lo, hi} = Enum.min_max([0.0 | values])
    span = if hi == lo, do: 1.0, else: hi - lo
    t0 = DateTime.to_unix(assigns.from)
    width_s = max(DateTime.to_unix(assigns.to) - t0, 1)
    x = fn at -> Float.round((DateTime.to_unix(at) - t0) / width_s * @width, 1) end
    y = fn v -> Float.round(6 + (hi - v) / span * (@height - 12), 1) end

    # A step line: the account only moves when a trade closes.
    line = fn %{points: points} ->
      points
      |> Enum.chunk_every(2, 1)
      |> Enum.map_join(" ", fn
        [a, b] -> "#{x.(a.time)},#{y.(a.equity)} #{x.(b.time)},#{y.(a.equity)}"
        [a] -> "#{x.(a.time)},#{y.(a.equity)} #{@width},#{y.(a.equity)}"
      end)
    end

    worst = main.points |> Enum.map(& &1.drawdown) |> Enum.min(fn -> 0.0 end)
    dd_span = if worst == 0, do: 1.0, else: abs(worst)

    assigns =
      assign(assigns,
        width: @width,
        height: @height,
        dd_height: @dd_height,
        zero: y.(0.0),
        solid: line.(main),
        dashed: assigns.with_rules && line.(assigns.without_rules),
        drawdown:
          "0,0 " <>
            Enum.map_join(main.points, " ", fn p ->
              "#{x.(p.time)},#{Float.round(abs(p.drawdown) / dd_span * (@dd_height - 2), 1)}"
            end) <> " #{@width},0"
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <svg
        role="img"
        aria-label="The account's running return with all the chosen strategies"
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
          :if={@dashed}
          points={@dashed}
          fill="none"
          stroke="var(--color-neutral-content)"
          stroke-width="1.5"
          stroke-dasharray="5 4"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          points={@solid}
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
            {if @with_rules, do: "With your safety rules", else: @label} {signed_pct(
              (@with_rules || @without_rules).total_return,
              0
            )}
          </span>
          <span :if={@with_rules} class="inline-flex items-center gap-1.5">
            <span
              aria-hidden="true"
              class="inline-block w-4 border-t border-dashed border-neutral-content"
            ></span>
            Without them {signed_pct(@without_rules.total_return, 0)}
          </span>
        </span>
        <span>{date(@from)} – {date(@to)}</span>
      </div>
      <svg
        role="img"
        aria-label="How far the account fell from its best"
        viewBox={"0 0 #{@width} #{@dd_height}"}
        preserveAspectRatio="none"
        class="block h-[34px] w-full"
      >
        <polygon points={@drawdown} fill="var(--color-error)" fill-opacity="0.45" />
      </svg>
      <p class="m-0 text-[12px] text-muted">
        Red: how far the account was below its best. Each trade is sized the way the live engine sizes it
        (its risk per trade against its stop), on one account.
      </p>
    </div>
    """
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
