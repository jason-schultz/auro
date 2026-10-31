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

  @doc "A paper book's name (`Opus.Options.Paper.books/0`), in both voices."
  @spec book_name(String.t()) :: OpusWeb.Copy.voices()
  def book_name("wheel"), do: copy("Wheel")
  def book_name("put_spread"), do: copy("Put spreads")
  def book_name("iron_condor"), do: copy("Iron condors")
  def book_name("ideas"), do: pcopy("paper book", "Ideas")
  def book_name("ideas_half"), do: copy("Ideas · half at double")
  def book_name("crash_puts"), do: copy("Crash puts")
  def book_name("crash_puts_half"), do: copy("Crash puts · half at double")
  def book_name(other), do: %{s: other, wsb: other}

  @doc "An option leg in a few words: `short 2 × $260.00 put`."
  @spec leg_words(map()) :: String.t()
  def leg_words(%{quantity: n} = p) when n > 1,
    do: "#{p.side} #{n} × #{money(p.strike)} #{p.kind}"

  def leg_words(p), do: "#{p.side} #{money(p.strike)} #{p.kind}"

  attr :label, :map, required: true, doc: "copy/1"
  attr :value, :string, required: true
  attr :tone, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-[12px] text-muted"><.t {@label} /></span>
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
end
