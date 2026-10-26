defmodule OpusWeb.Components.PaperParts do
  @moduledoc """
  Pieces every paper-book view shares (`OpusWeb.Components.PaperBook`,
  `OpusWeb.Components.PaperTrades`): headline stats and facts, the "goes
  well / goes wrong" playbook cards, the table of what a move in the
  underlying would mean at expiry, and event labels.
  """
  use Phoenix.Component

  import OpusWeb.Copy
  import OpusWeb.Format

  attr :label, :string, required: true
  attr :wsb, :string, required: true
  attr :value, :string, required: true
  attr :tone, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-[12px] text-muted"><.t s={@label} wsb={@wsb} /></span>
      <span class={["text-[15px] font-semibold", @tone]}>{@value}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :note, :string, default: nil
  attr :tone, :string, default: nil

  def fact(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-[12px] text-muted">{@label}</span>
      <span class={["text-[15px] font-semibold", @tone]}>{@value || "—"}</span>
      <span :if={@note} class="text-[12px] text-muted">{@note}</span>
    </div>
    """
  end

  attr :tone, :string, required: true
  slot :title, required: true
  slot :inner_block, required: true

  def play_card(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-2 rounded-box border px-4 py-3",
      if(@tone == "success", do: "border-success/40", else: "border-error/40")
    ]}>
      <span class={[
        "text-[13px] font-semibold",
        if(@tone == "success", do: "text-success", else: "text-error")
      ]}>
        {render_slot(@title)}
      </span>
      <ol class="m-0 flex list-decimal flex-col gap-1.5 pl-4 text-[13px]">
        {render_slot(@inner_block)}
      </ol>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :move, :string, required: true
  attr :what, :string, required: true

  def change_table(assigns) do
    ~H"""
    <table class="mt-1 w-full border-collapse text-[12px]">
      <thead>
        <tr class="text-left text-muted">
          <th class="py-1 font-medium">{@move}</th>
          <th class="py-1 font-medium">to</th>
          <th class="py-1 text-right font-medium">P&L of the {@what}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{label, price, pnl} <- @rows} class="border-t border-base-300">
          <td class="py-1">{label}</td>
          <td class="py-1">{money(price)}</td>
          <td class={["py-1 text-right", tone(pnl)]}>{money(pnl)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  @drops [{"5%", 0.05}, {"10%", 0.10}, {"20%", 0.20}, {"34% (Covid)", 0.34}]
  @rises [{"5%", 0.05}, {"10%", 0.10}, {"20%", 0.20}]

  @doc """
  `{label, price, pnl}` rows for the change table: drops of 5%, 10%, 20%
  and a Covid-size 34% from `now`, or rises of 5%, 10% and 20%, with `pnl`
  giving the P&L at each price. Empty without a price.
  """
  @spec moves(float() | nil, :down | :up, (float() -> float() | nil)) :: list()
  def moves(nil, _direction, _pnl), do: []

  def moves(now, :down, pnl),
    do: for({label, d} <- @drops, p = now * (1 - d), do: {label, p, pnl.(p)})

  def moves(now, :up, pnl),
    do: for({label, d} <- @rises, p = now * (1 + d), do: {label, p, pnl.(p)})

  attr :kind, :string, required: true
  attr :book, :string, required: true

  def event_label(assigns) do
    {serious, meme} = event_words(assigns.book, assigns.kind)
    assigns = assign(assigns, serious: serious, meme: meme)

    ~H"""
    <.t s={@serious} wsb={@meme} />
    """
  end

  defp event_words("wheel", "open"), do: {"sold an option", "sold some theta"}
  defp event_words("wheel", "close"), do: {"bought it back", "took the tendies early"}
  defp event_words("wheel", "expire"), do: {"expired worthless", "expired worthless (free money)"}

  defp event_words("wheel", "assign"),
    do: {"assigned 100 shares", "got assigned (bagholder mode)"}

  defp event_words("wheel", "call_away"), do: {"called away", "called away (tendies)"}
  defp event_words(_book, "open"), do: {"opened a leg", "aped in"}
  defp event_words(_book, "close"), do: {"closed a leg", "took it off the table"}
  defp event_words(_book, "expire"), do: {"settled at expiry", "expired (it is what it is)"}

  def day(date), do: Calendar.strftime(date, "%b %-d")

  def tone(nil), do: nil
  def tone(value) when value < 0, do: "text-error"
  def tone(value) when value > 0, do: "text-success"
  def tone(_value), do: nil
end
