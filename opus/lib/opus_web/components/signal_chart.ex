defmodule OpusWeb.SignalChart do
  @moduledoc """
  The signal chart section shared by a strategy's page and the builder's
  preview: candles with every buy (▲) and sell (▼) the rules made, the
  indicators themselves (lines on the candles, oscillators in panels with
  their threshold levels), the rule strips that say why, the trades in the
  window as buttons, and the chosen trade told as a sentence. Data from
  `Opus.Trading.SignalChart`.
  """
  use Phoenix.Component

  import OpusWeb.CandleChart
  import OpusWeb.Format
  import OpusWeb.Copy, only: [t: 1, copy: 1]

  alias Opus.Trading.StrategyWords

  attr :chart, :map, required: true, doc: "SignalChart.shape/3"
  attr :definition, :map, required: true
  attr :granularity, :string, required: true
  attr :label, :string, required: true
  attr :focus, :integer, default: nil
  attr :pick_event, :string, default: "pick_trade"

  def signal_chart(assigns) do
    assigns =
      assign(assigns,
        chosen:
          Enum.find(assigns.chart.trades, &(&1.id == assigns.focus)) ||
            List.last(assigns.chart.trades)
      )

    ~H"""
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap gap-x-5 gap-y-1 text-[13px] text-muted">
        <span><span aria-hidden="true" class="text-info">▲</span> <.t {copy("Buy")} /></span>
        <span><span aria-hidden="true" class="text-warning">▼</span> <.t {copy("Sell")} /></span>
        <span><span
          aria-hidden="true"
          class="mr-1.5 inline-block h-3 w-4 bg-info/15 align-middle"
        ></span><.t {copy("Time in a trade")} /></span>
      </div>
      <.candle_chart
        candles={@chart.candles}
        signals={@chart}
        marker_event={@pick_event}
        focus={@chosen && @chosen.id}
        label={@label}
      />
      <p :if={@chart.lanes != []} class="text-[13px] text-muted">
        <.t {copy("Each strip under the chart is one rule, lit on the bars it was true. A signal fires where its rules line up.")} />
      </p>
      <%= if @chart.trades == [] do %>
        <p class="text-[14px] text-muted">
          <.t {copy("No trades in this window: the rules never lined up.")} />
        </p>
      <% else %>
        <div class="flex flex-col gap-2 rounded-field bg-base-100 px-4 py-3">
          <span class="text-[13px] font-medium text-muted">
            <.t {copy("Selected trade")} />
          </span>
          <p class="m-0 text-[14px]">
            {story(@chosen, @definition, @granularity)}
            <span
              :if={@chosen && @chosen.return}
              class={["font-semibold", tone(shown(@chosen.return))]}
            >
              {signed_pct(@chosen.return)}
            </span>
          </p>
          <div class="flex flex-wrap gap-1.5" role="group" aria-label="Trades in this window">
            <button
              :for={trade <- @chart.trades}
              type="button"
              phx-click={@pick_event}
              phx-value-trade={trade.id}
              aria-pressed={to_string(@chosen && trade.id == @chosen.id)}
              class={[
                "min-h-9 rounded-field border px-2.5 text-[12px]",
                if(@chosen && trade.id == @chosen.id,
                  do: "border-primary text-base-content",
                  else: "border-base-300 text-muted"
                )
              ]}
            >
              {day(trade.entry_at, @granularity)}
              <span :if={trade.return} aria-hidden="true" class="text-muted">·</span>
              <span :if={trade.return} class={["font-medium", tone(shown(trade.return))]}>
                {signed_pct(trade.return)}
              </span>
              <span :if={!trade.return} class="text-muted">· open</span>
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :chart, :map, required: true, doc: "SignalChart.shape/3"
  attr :label, :string, required: true

  @doc "A small closing-price line with the buy and sell markers, for a card."
  def signal_sparkline(assigns) do
    assigns = assign(assigns, spark(assigns.chart))

    ~H"""
    <svg
      role="img"
      aria-label={@label}
      viewBox="0 0 520 96"
      preserveAspectRatio="none"
      class="block h-24 w-full"
    >
      <polyline
        points={@points}
        fill="none"
        stroke="var(--color-neutral-content)"
        stroke-opacity="0.7"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
      />
      <path :for={m <- @markers} d={m.path} fill={m.color} />
    </svg>
    """
  end

  defp spark(%{candles: []}), do: %{points: "", markers: []}

  defp spark(%{candles: candles, markers: markers}) do
    closes = Enum.map(candles, & &1.close)
    {lo, hi} = Enum.min_max(closes)
    span = max(hi - lo, hi * 0.001)
    n = max(length(closes) - 1, 1)
    x = fn i -> Float.round(6 + i / n * 508, 1) end
    y = fn v -> Float.round(14 + (1 - (v - lo) / span) * 68, 1) end

    %{
      points:
        closes |> Enum.with_index() |> Enum.map_join(" ", fn {c, i} -> "#{x.(i)},#{y.(c)}" end),
      markers:
        Enum.map(markers, fn m ->
          cx = x.(m.index)
          cy = y.(Enum.at(closes, m.index))

          case m.kind do
            :buy ->
              %{
                path: "M#{cx} #{cy + 5} L#{cx + 5} #{cy + 14} L#{cx - 5} #{cy + 14} Z",
                color: "var(--color-info)"
              }

            :sell ->
              %{
                path: "M#{cx} #{cy - 5} L#{cx + 5} #{cy - 14} L#{cx - 5} #{cy - 14} Z",
                color: "var(--color-warning)"
              }
          end
        end)
    }
  end

  @doc """
  A trade from the chart in plain words: what opened it and what closed it.
  The result follows it on the page, coloured (`OpusWeb.Format.tone/1`).
  """
  @spec story(map() | nil, map(), String.t()) :: String.t()
  def story(nil, _definition, _granularity), do: ""

  def story(trade, definition, granularity) do
    {opened, closed, side} =
      if trade.direction == "short",
        do: {"Sold short", "Bought back", "short"},
        else: {"Bought", "Sold", "long"}

    because = StrategyWords.selector(definition, ["entry", side], granularity)

    open =
      "#{opened} #{day(trade.entry_at, granularity)} at #{price(trade.entry_price)}, because #{because}."

    close =
      case trade.reason do
        nil ->
          "Still open at the end of the chart."

        reason ->
          "#{closed} #{day(trade.exit_at, granularity)} at #{price(trade.exit_price)} " <>
            "#{why(reason, definition, side, granularity)}. Result:"
      end

    open <> " " <> close
  end

  defp why("rule", definition, side, granularity),
    do: "because #{StrategyWords.selector(definition, ["exit", side], granularity)}"

  defp why("stop_loss", _definition, _side, _granularity), do: "when the stop was hit"
  defp why("hold_limit", _definition, _side, _granularity), do: "when it reached its hold limit"
  defp why(_other, _definition, _side, _granularity), do: "at the end of the data"

  # A return as the page shows it (one decimal of a percent), so one that
  # reads 0.0% isn't coloured.
  defp shown(r), do: Float.round(r * 100, 1)

  # Daily bars by date; intraday bars by New York date and time.
  defp day(at, "D"), do: day(at)
  defp day(nil, _intraday), do: "—"
  defp day(at, _intraday), do: stamp(at)
end
