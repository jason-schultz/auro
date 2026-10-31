defmodule OpusWeb.Components.TradeStory do
  @moduledoc """
  Live trades on the Journal page: a filter by strategy, the list of recent
  trades and, for the chosen one, its story in plain words (`Opus.Journal.TradeStory`): why it
  opened and closed, its numbers, and what to take from it.

  Selection lives in the URL (`/journal?strategy=<id>&trade=<id>`), handled
  by `OpusWeb.JournalLive`.
  """
  use Phoenix.Component
  use OpusWeb, :verified_routes

  import OpusWeb.Copy
  import OpusWeb.Format
  import OpusWeb.Components.PaperParts, only: [fact: 1]

  alias Opus.Journal.TradeStory, as: Story
  alias Phoenix.LiveView.JS

  attr :strategies, :list, required: true
  attr :selected, :string, default: nil

  @doc "One button per strategy that traded, with its record, to narrow the list."
  def strategy_filter(assigns) do
    ~H"""
    <nav aria-label="Strategy" class="flex flex-wrap gap-2 text-[13px]">
      <.link
        patch={~p"/journal"}
        class={chip_class(@selected == nil)}
      >
        All
      </.link>
      <.link
        :for={s <- @strategies}
        patch={~p"/journal?#{[strategy: s.strategy_id]}"}
        class={chip_class(@selected == s.strategy_id)}
      >
        {s.name}
        <span class="text-muted">· {s.trades} closed</span>
        <span :if={s.trades > 0} class={tone(s.pnl_cad)}>{money(s.pnl_cad)}</span>
        <span :if={s.trades > 0} class="text-muted">· {pct(s.win_rate_pct / 100, 0)} won</span>
        <span :if={s.open_trades > 0} class="text-muted">· {s.open_trades} open</span>
      </.link>
    </nav>
    """
  end

  @doc """
  A filter or tab pill's classes, chosen or not. The outline is a ring (a
  box shadow), which stays smooth round the ends where a 1px border looks
  jagged on the dark theme.
  """
  @spec chip_class(boolean()) :: [String.t()]
  def chip_class(chosen),
    do: ["rounded-full px-3 py-1 ring-1 ring-inset transition-colors", chip_tone(chosen)]

  defp chip_tone(true), do: "bg-primary/10 text-primary ring-primary/70"
  defp chip_tone(false), do: "bg-base-200 ring-base-content/20 hover:ring-primary/70"

  @doc """
  A clickable table row's classes: its cells carry the highlight, rounded
  at both ends; pad the first and last cells so it sits evenly round the
  text. No lines between rows (a square line beside a rounded highlight
  looks broken): the table spaces them instead (`list_table_class/0`).
  """
  @spec row_class(boolean()) :: [String.t() | false]
  def row_class(chosen),
    do: [
      "cursor-pointer",
      "[&>td:first-child]:rounded-l-field [&>td:last-child]:rounded-r-field",
      "hover:[&>td]:bg-base-300/60",
      chosen && "[&>td]:bg-base-300"
    ]

  @doc "The table of clickable rows (`row_class/1`): rows a hair apart, no lines."
  @spec list_table_class() :: String.t()
  def list_table_class,
    do: "w-full border-separate border-spacing-x-0 border-spacing-y-0.5 text-sm"

  attr :trades, :list, required: true
  attr :selected, :string, default: nil
  attr :strategy, :string, default: nil

  def trade_list(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-2 py-1.5">
      <table class={list_table_class()}>
        <thead>
          <tr class="text-left text-xs text-muted">
            <th class="border-b border-base-300 py-2.5 pl-3 font-medium">Opened (ET)</th>
            <th class="border-b border-base-300 py-2.5 pl-4 font-medium">
              <.t {copy("Trade")} />
            </th>
            <th class="border-b border-base-300 py-2.5 text-right font-medium">
              <.t {copy("Result")} />
            </th>
            <th class="border-b border-base-300 py-2.5 pr-3 pl-4 font-medium">
              <.t {copy("Why it closed")} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={t <- @trades}
            phx-click={JS.patch(trade_path(@strategy, t.id))}
            class={row_class(t.id == @selected)}
          >
            <td class="py-2.5 pl-3 whitespace-nowrap">
              <.link patch={trade_path(@strategy, t.id)} class="text-primary hover:underline">
                {stamp(t.entry_time)}
              </.link>
            </td>
            <td class="py-2.5 pl-4">
              {Story.market(t)} {String.downcase(t.direction || "")}
              <span :if={!@strategy} class="block text-[12px] text-muted">{t.strategy}</span>
            </td>
            <td
              :if={t.status == "open"}
              class={["py-2.5 text-right whitespace-nowrap", tone(t[:now_pct])]}
            >
              {if t[:now_pct], do: signed_pct(t.now_pct, 2), else: "open"}
              <span class="block text-[12px] text-muted">
                {if t[:now_pct], do: "open, now", else: "no price yet"}
              </span>
            </td>
            <td
              :if={t.status != "open"}
              class={["py-2.5 text-right whitespace-nowrap", tone(t.pnl)]}
            >
              {money(t.pnl)}
              <span :if={t.pnl_percent} class="block text-[12px] text-muted">
                {signed_pct(t.pnl_percent, 2)}
              </span>
            </td>
            <td class="py-2.5 pr-3 pl-4 text-muted">{t.why_closed}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp trade_path(nil, id), do: ~p"/journal?#{[trade: id]}"
  defp trade_path(strategy, id), do: ~p"/journal?#{[strategy: strategy, trade: id]}"

  attr :trade, :map, required: true

  def trade_panel(assigns) do
    ~H"""
    <section
      aria-label="Trade"
      class="flex flex-col gap-5 rounded-box border border-base-300 bg-base-200 px-5 py-4"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class={["text-[18px] font-semibold", headline_tone(@trade.story.result)]}>
          {@trade.story.headline}
        </span>
        <span class="text-[13px] text-muted">
          {@trade.strategy || "Unknown strategy"} · {Story.market(@trade)}
        </span>
      </div>

      <dl class="m-0 grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-[14px]">
        <%= for {label, text} <- @trade.story.story do %>
          <dt class="text-muted">{label}</dt>
          <dd class="m-0">{text}</dd>
        <% end %>
      </dl>

      <div class="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <.fact
          :for={{label, value, note} <- @trade.story.numbers}
          label={label}
          value={value}
          note={note}
        />
      </div>

      <div class="flex flex-col gap-1.5">
        <span class="text-[14px] font-medium">
          <.t {copy("What to take from it")} />
        </span>
        <ul class="m-0 flex list-disc flex-col gap-1.5 pl-5 text-[14px]">
          <li :for={line <- @trade.story.takeaways}>{line}</li>
        </ul>
      </div>

      <p class="m-0 text-[13px] text-muted">
        {closed_count(@trade.strategy_closed_trades)}
        <.link
          :if={@trade.live_strategy_id}
          navigate={~p"/strategies/#{@trade.live_strategy_id}"}
          class="text-primary hover:underline"
        >
          See the strategy's whole record →
        </.link>
      </p>
    </section>
    """
  end

  defp closed_count(1), do: "This strategy has closed 1 live trade."
  defp closed_count(n), do: "This strategy has closed #{n} live trades."

  defp headline_tone(:win), do: "text-success"
  defp headline_tone(:loss), do: "text-error"
  defp headline_tone(_result), do: nil
end
