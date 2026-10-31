defmodule OpusWeb.Components.OptionJournal do
  @moduledoc """
  The Journal's Options tab: the options paper books' closed trades and the
  chosen trade's story (`Opus.Journal.OptionStory`); its summary cards are
  the Journal's shared ones (`Opus.Journal.Cards`).
  Selection lives in the URL (`/journal?tab=options&option=7`), handled by
  `OpusWeb.JournalLive`.
  """
  use Phoenix.Component
  use OpusWeb, :verified_routes

  import OpusWeb.Copy
  import OpusWeb.Format
  import OpusWeb.Components.PaperParts, only: [book_name: 1, fact: 1]
  import OpusWeb.Components.TradeStory, only: [list_table_class: 0, row_class: 1]

  alias Opus.Journal.OptionStory
  alias Phoenix.LiveView.JS

  attr :trades, :list, required: true
  attr :selected, :integer, default: nil

  def option_list(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-2 py-1.5">
      <table class={list_table_class()}>
        <thead>
          <tr class="text-left text-xs text-muted">
            <th class="border-b border-base-300 py-2.5 pl-3 font-medium"><.t {copy("Closed")} /></th>
            <th class="border-b border-base-300 py-2.5 pl-4 font-medium"><.t {copy("Trade")} /></th>
            <th class="border-b border-base-300 py-2.5 text-right font-medium">
              <.t {copy("Result")} />
            </th>
            <th class="border-b border-base-300 py-2.5 pr-3 pl-4 font-medium">
              <.t {copy("How it ended")} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={t <- @trades}
            phx-click={JS.patch(path(t))}
            class={row_class(t.id == @selected)}
          >
            <td class="py-2.5 pl-3 whitespace-nowrap">
              <.link patch={path(t)} class="text-primary hover:underline">{day(t.closed_on)}</.link>
            </td>
            <td class="py-2.5 pl-4">
              {t.symbol} {String.replace(t.structure, "_", " ")}
              <span class="block text-[12px] text-muted"><.t {book_name(t.book)} /></span>
            </td>
            <td class={["py-2.5 text-right whitespace-nowrap font-medium", tone(t.pnl)]}>
              {signed_money(t.pnl)}
            </td>
            <td class="py-2.5 pr-3 pl-4 text-muted">{ended_word(t.ended)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :trade, :map, required: true

  def option_panel(assigns) do
    assigns = assign(assigns, story: OptionStory.tell(assigns.trade))

    ~H"""
    <section
      aria-label="Options trade"
      class="flex flex-col gap-5 rounded-box border border-base-300 bg-base-200 px-5 py-4"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class={["text-[18px] font-semibold", tone(@trade.pnl)]}>{@story.headline}</span>
        <span class="text-[13px] text-muted">
          <.t {book_name(@trade.book)} /> · {@trade.symbol}
        </span>
      </div>

      <dl class="m-0 grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-[14px]">
        <%= for {label, text} <- @story.story do %>
          <dt class="text-muted">{label}</dt>
          <dd class="m-0">{text}</dd>
        <% end %>
      </dl>

      <div class="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <.fact :for={{label, value, note} <- @story.numbers} label={label} value={value} note={note} />
      </div>

      <.link navigate={book_path(@trade)} class="text-[13px] text-primary hover:underline">
        <.t {copy("See it in its book on the Options page")} /> →
      </.link>
    </section>
    """
  end

  defp path(t), do: ~p"/journal?#{[tab: "options", option: t.id]}"

  # The trade in its book on the Options page: the wheel's trades are keyed
  # by underlying, every other book's by id.
  defp book_path(%{book: "wheel", symbol: symbol}),
    do: ~p"/options?view=paper&book=wheel&trade=#{symbol}"

  defp book_path(t), do: ~p"/options?view=paper&book=#{t.book}&trade=#{t.id}"

  defp ended_word(:assigned), do: "assigned"
  defp ended_word(:called_away), do: "called away"
  defp ended_word(:expired), do: "expired"
  defp ended_word(:closed), do: "closed early"
end
