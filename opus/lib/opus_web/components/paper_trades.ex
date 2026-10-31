defmodule OpusWeb.Components.PaperTrades do
  @moduledoc """
  The paper books that trade whole structures rather than the wheel's one
  leg at a time (research/options_paper_engine.md, v2): put credit spreads,
  iron condors, the ideas calls and the crash puts (each also "half at
  double"). The left column lists
  the book's trades and, for the chosen one, its legs; the right shows the
  book overview, or the chosen trade: its structure, what it can make and
  lose, what the rules do next, what to expect if it goes well or wrong,
  and its payoff chart. A chosen leg shows its own quote above that.

  Selection lives in the URL (`?view=paper&book=iron_condor&trade=7&leg=21`),
  handled by `OpusWeb.OptionsLive`.
  """
  use Phoenix.Component
  use OpusWeb, :verified_routes

  import OpusWeb.Copy
  import OpusWeb.Format
  import OpusWeb.PayoffChart
  import OpusWeb.Components.PaperParts

  alias Opus.Options.Paper.{Legs, Pick}

  @manage_dte 21
  @half_books ~w(ideas_half crash_puts_half)

  attr :book, :map, required: true
  attr :trade, :map, default: nil
  attr :leg, :map, default: nil
  attr :analysis, :map, default: nil
  attr :now, :map, default: %{}

  def body(assigns) do
    ~H"""
    <div
      :if={@book.trades != []}
      class="grid items-start gap-5 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]"
    >
      <nav aria-label="Trades" class="flex flex-col gap-2">
        <.link
          patch={~p"/options?view=paper&book=#{@book.strategy}"}
          class={[
            "rounded-field px-3 py-2 text-[13px]",
            if(@trade, do: "text-muted hover:text-base-content", else: "bg-base-300 font-medium")
          ]}
        >
          <.t {copy("Overview")} />
        </.link>
        <%= for {label, trades} <- trade_groups(@book.trades), trades != [] do %>
          <span class="mt-2 px-1 text-[11px] font-medium uppercase tracking-wide text-muted">
            <.t {label} /> · {length(trades)}
          </span>
          <.trade_item
            :for={trade <- trades}
            trade={trade}
            selected={@trade}
            leg={@leg}
            book={@book.strategy}
          />
        <% end %>
      </nav>

      <div class="min-w-0">
        <.overview :if={@trade == nil} book={@book} />
        <.trade_panel
          :if={@trade}
          trade={@trade}
          leg={@leg}
          analysis={@analysis}
          book={@book}
          now={@now[@trade.symbol]}
        />
      </div>
    </div>
    """
  end

  # Open trades first, then the closed ones, each under its own heading:
  # a closed trade between two open ones reads as if it were still on.
  defp trade_groups(trades) do
    {open, closed} = Enum.split_with(trades, &(&1.status == "open"))
    [{copy("Open"), open}, {copy("Closed"), closed}]
  end

  attr :trade, :map, required: true
  attr :selected, :map, default: nil
  attr :leg, :map, default: nil
  attr :book, :string, required: true

  defp trade_item(assigns) do
    ~H"""
    <div class="flex flex-col">
      <.link
        patch={
          if @selected && @selected.id == @trade.id,
            do: ~p"/options?view=paper&book=#{@book}",
            else: ~p"/options?view=paper&book=#{@book}&trade=#{@trade.id}"
        }
        class={[
          "flex flex-col gap-0.5 rounded-field border px-3 py-2",
          if(@selected && @selected.id == @trade.id,
            do: "border-primary bg-base-300",
            else: "border-base-300 hover:border-primary"
          ),
          @trade.status != "open" && "opacity-70"
        ]}
      >
        <span class="flex items-baseline justify-between gap-3">
          <span class="text-[14px] font-medium">{@trade.symbol} {structure_name(@trade.structure)}</span>
          <span class={["text-[14px] font-medium", tone(@trade.pnl)]}>{money(@trade.pnl)}</span>
        </span>
        <span class="text-[12px] text-muted">
          {strikes(@trade)} · {day(@trade.expiration)} · {@trade.status}
        </span>
      </.link>
      <ol
        :if={@selected && @selected.id == @trade.id}
        class="m-0 ml-3 flex list-none flex-col border-l border-base-300 p-0"
      >
        <li :for={leg <- @trade.legs}>
          <.link
            patch={
              if @leg && @leg.position.id == leg.id,
                do: ~p"/options?view=paper&book=#{@book}&trade=#{@trade.id}",
                else: ~p"/options?view=paper&book=#{@book}&trade=#{@trade.id}&leg=#{leg.id}"
            }
            class={[
              "flex justify-between gap-3 px-3 py-1.5 text-[13px]",
              if(@leg && @leg.position.id == leg.id,
                do: "font-medium text-primary",
                else: "text-muted hover:text-base-content"
              )
            ]}
          >
            <span>{leg_words(leg)}</span>
            <span>{leg.status}</span>
          </.link>
        </li>
      </ol>
    </div>
    """
  end

  # The open trades side by side: room before trouble, the next date the
  # rules act, and P&L, plus what the book has at stake.
  attr :book, :map, required: true

  defp overview(assigns) do
    open = Enum.filter(assigns.book.trades, &(&1.status == "open"))

    at_stake =
      Enum.sum_by(open, fn trade ->
        if credit?(trade), do: trade.summary.max_loss || 0.0, else: -trade.summary.net
      end)

    assigns = assign(assigns, open: open, at_stake: at_stake)

    ~H"""
    <section aria-label="Book overview" class="flex flex-col gap-4">
      <p class="text-[13px] text-muted">
        {length(@open)} open {if length(@open) == 1, do: "trade", else: "trades"}, {money(@at_stake)} at stake
        ({at_stake_words(@book.strategy)}). Pick a trade for its legs and payoff.
      </p>
      <table :if={@open != []} class="w-full border-collapse text-[13px]">
        <thead>
          <tr class="text-left text-[11px] text-muted">
            <th class="border-b border-base-300 py-2 font-medium">Trade</th>
            <th class="border-b border-base-300 px-2 py-2 font-medium">Where it stands</th>
            <th class="border-b border-base-300 px-2 py-2 font-medium">Next decision</th>
            <th class="border-b border-base-300 py-2 pl-2 text-right font-medium">P&L</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={trade <- @open} class="border-b border-neutral last:border-b-0">
            <td class="py-2">
              <.link
                patch={~p"/options?view=paper&book=#{@book.strategy}&trade=#{trade.id}"}
                class="hover:text-primary"
              >
                <span class="font-medium">{trade.symbol}</span>
                <span class="text-muted">{strikes(trade)} {structure_name(trade.structure)}</span>
              </.link>
            </td>
            <td class="px-2 py-2">{standing(trade)}</td>
            <td class="px-2 py-2 text-muted">{next_decision(trade)}</td>
            <td class={["py-2 pl-2 text-right", tone(trade.pnl)]}>{money(trade.pnl)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr :trade, :map, required: true
  attr :leg, :map, default: nil
  attr :analysis, :map, default: nil
  attr :book, :map, required: true
  attr :now, :map, default: nil

  defp trade_panel(assigns) do
    trade = assigns.trade
    open_legs = Enum.filter(trade.legs, &(&1.status == "open"))

    assigns =
      assign(assigns,
        open_legs: open_legs,
        days_left: trade.expiration && Date.diff(trade.expiration, Opus.Clock.today()),
        manage_on: trade.expiration && Date.add(trade.expiration, -@manage_dte)
      )

    ~H"""
    <section aria-label={"#{@trade.symbol} trade"} class="flex flex-col gap-4">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class="text-[15px] font-semibold">
          {@trade.symbol} {strikes(@trade)} {structure_name(@trade.structure)}
          <span class="font-normal text-muted">· {day(@trade.expiration)}</span>
        </span>
        <span class="text-[13px] text-muted">
          {if @trade.status == "open",
            do: "#{@days_left} days left",
            else: "closed #{@trade.closed_on && day(@trade.closed_on)}"}
        </span>
      </div>
      <p :if={@trade.status == "open"} class="-mt-2 text-[13px] text-muted">
        {@trade.symbol}
        <span :if={@now}>{spot_words(@now)};</span>
        valued at {money(@trade.spot)} in the book's last snapshot.
      </p>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <.fact
          label={if @trade.summary.net >= 0, do: "Net credit", else: "Net debit"}
          value={money(abs(@trade.summary.net))}
        />
        <.fact label="Max profit" value={limit(@trade.summary.max_profit)} />
        <.fact label="Max loss" value={limit(@trade.summary.max_loss)} />
        <.fact
          label={if length(@trade.summary.breakevens) > 1, do: "Break-evens", else: "Break-even"}
          value={Enum.map_join(@trade.summary.breakevens, " / ", &money/1)}
        />
        <.fact label="P&L" value={money(@trade.pnl)} tone={tone(@trade.pnl)} />
      </div>

      <table class="w-full border-collapse text-[13px]">
        <thead>
          <tr class="text-left text-[11px] text-muted">
            <th class="border-b border-base-300 py-2 font-medium">Leg</th>
            <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Opened at</th>
            <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Mark</th>
            <th class="border-b border-base-300 py-2 pl-2 text-right font-medium">Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={leg <- @trade.legs} class="border-b border-neutral last:border-b-0">
            <td class="py-1.5">
              <.link
                patch={
                  ~p"/options?view=paper&book=#{@book.strategy}&trade=#{@trade.id}&leg=#{leg.id}"
                }
                class="hover:text-primary"
              >
                {leg_words(leg)}
              </.link>
            </td>
            <td class="px-2 py-1.5 text-right">{num(leg.open_price)}</td>
            <td class="px-2 py-1.5 text-right">{num(@trade.marks[leg.id])}</td>
            <td class="py-1.5 pl-2 text-right text-muted">{leg.status}</td>
          </tr>
        </tbody>
      </table>

      <.leg_facts :if={@leg} leg={@leg} />

      <div :if={@trade.status == "open"} class="flex flex-col gap-1.5">
        <span class="text-[13px] font-medium">
          <.t {copy("What happens next")} />
        </span>
        <ol class="m-0 flex list-decimal flex-col gap-1.5 pl-4 text-[13px]">
          <.plan trade={@trade} manage_on={@manage_on} book={@book.strategy} />
        </ol>
      </div>

      <.playbook
        :if={@trade.status == "open"}
        trade={@trade}
        open_legs={@open_legs}
        book={@book.strategy}
      />

      <div :if={@trade.status == "open"} class="flex flex-col gap-1">
        <span class="text-[12px] text-muted">
          P&L by {@trade.symbol} price, today and at expiry, for the whole trade.
        </span>
        <%= if @analysis do %>
          <.payoff_chart analysis={@analysis} class="hidden sm:block" />
          <.payoff_chart analysis={@analysis} compact class="sm:hidden" />
        <% else %>
          <p class="text-[13px] text-muted">
            The payoff chart needs the engine, which is not reachable.
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  # One leg's own numbers: how it was opened and its latest quote.
  attr :leg, :map, required: true

  # A closed leg shows what it closed at and its realized P&L, not today's
  # quote of a contract it no longer holds.
  defp leg_facts(assigns) do
    %{position: p, quote: quote} = assigns.leg
    open? = p.status == "open"
    mark = if open?, do: Pick.mid(quote), else: p.close_price

    assigns =
      assign(assigns,
        p: p,
        quote: quote,
        open?: open?,
        mark: mark,
        pnl:
          if(open?,
            do: mark && Legs.sign(p) * (p.open_price - mark) * Pick.multiplier() * p.quantity,
            else: Legs.realized(p)
          )
      )

    ~H"""
    <div class="flex flex-col gap-2 rounded-box border border-base-300 px-4 py-3">
      <span class="text-[13px] font-medium">
        {String.capitalize(@p.side)} {money(@p.strike)} {@p.kind} · {if @p.side == "short",
          do: "sold",
          else: "bought"} {day(@p.opened_on)} at {money(@p.open_price)}
      </span>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.fact
          :if={@open?}
          label="Worth now"
          value={@mark && money(@mark)}
          note={@quote && "bid #{num(@quote.bid)} · ask #{num(@quote.ask)}"}
        />
        <.fact
          :if={!@open?}
          label={"Closed #{day(@p.closed_on)}"}
          value={@mark && money(@mark)}
          note={@p.status}
        />
        <.fact
          label={if @open?, do: "Leg P&L", else: "Leg P&L, realized"}
          value={money(@pnl)}
          tone={tone(@pnl)}
        />
        <.fact label="Delta" value={@quote && num(@quote.delta)} />
        <.fact label="Implied vol" value={@quote && @quote.iv_pct && "#{num(@quote.iv_pct, 1)}%"} />
      </div>
    </div>
    """
  end

  attr :trade, :map, required: true
  attr :manage_on, :any, required: true
  attr :book, :string, required: true

  defp plan(%{book: book} = assigns) when book in @half_books do
    [leg] = Enum.filter(assigns.trade.legs, &(&1.status == "open"))
    assigns = assign(assigns, leg: leg, paid: leg.open_price, roll?: book == "crash_puts_half")

    ~H"""
    <li :if={@leg.quantity > 1}>
      <span class="font-medium">Any day:</span>
      if its bid reaches {money(@paid * 2)} (double), {div(@leg.quantity, 2)} of the {@leg.quantity} contracts are sold,
      which pays back what all of them cost. The rest ride for free.
    </li>
    <li :if={@leg.quantity > 1 and not @roll?}>
      <span class="font-medium">Any day:</span>
      all of it is sold if the bid falls to {money(@paid / 2)} (half).
    </li>
    <li :if={@leg.quantity == 1}>
      <span class="font-medium">Any day:</span>
      half was sold at double. The rest is sold if its bid falls back to {money(@paid)}, the
      price paid, so the trade still ends up ahead.
    </li>
    <li>
      <span class="font-medium">{day(@manage_on)} (21 days left):</span>
      sold at the bid, whatever it's worth{if @roll?,
        do: ", and next month's two −0.10 delta puts are bought: the roll",
        else: ""}.
    </li>
    """
  end

  defp plan(%{trade: %{structure: structure}} = assigns)
       when structure in ~w(put_spread iron_condor) do
    assigns = assign(assigns, half: assigns.trade.summary.net / 2)

    ~H"""
    <li>
      <span class="font-medium">Any day:</span>
      the whole trade is bought back if it can be closed for {money(@half / 100)} a share or less
      (half the credit), keeping about {money(@half)}.
    </li>
    <li>
      <span class="font-medium">{day(@manage_on)} (21 days left):</span>
      closed at whatever it costs then.
    </li>
    <li>
      <span class="font-medium">{day(@trade.expiration)} (expiry):</span>
      only if a leg had no fill to close it: every leg settles at its intrinsic value in cash. No
      shares change hands.
    </li>
    """
  end

  defp plan(%{trade: %{structure: "long_call"}} = assigns) do
    assigns = assign(assigns, paid: hd(assigns.trade.legs).open_price)

    ~H"""
    <li>
      <span class="font-medium">Any day:</span>
      sold if its bid reaches {money(@paid * 2)} (double) or falls to {money(@paid / 2)} (half).
    </li>
    <li>
      <span class="font-medium">{day(@manage_on)} (21 days left):</span>
      sold at the bid, whatever it's worth.
    </li>
    """
  end

  defp plan(%{trade: %{structure: "long_put"}} = assigns) do
    ~H"""
    <li>
      <span class="font-medium">Until {day(@manage_on)}:</span>
      held whatever happens. There is no take-profit: a crash shows its full payoff at the roll.
    </li>
    <li>
      <span class="font-medium">{day(@manage_on)} (21 days left):</span>
      sold at the bid and next month's −0.10 delta put bought: the roll.
    </li>
    """
  end

  attr :trade, :map, required: true
  attr :open_legs, :list, required: true
  attr :book, :string, required: true

  defp playbook(%{trade: %{structure: "put_spread"}} = assigns) do
    [long, short] = Enum.sort_by(assigns.open_legs, & &1.strike)
    pnl = &Legs.at_expiry(assigns.open_legs, &1)

    assigns =
      assign(assigns, long: long, short: short, drops: moves(assigns.trade.spot, :down, pnl))

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li>
          {@trade.symbol} stays above {money(@short.strike)}, and the spread loses value every day.
        </li>
        <li>
          At the first daily check it can be bought back for half the credit, it is: about {money(
            @trade.summary.net / 2
          )} kept. Otherwise it's closed at 21 days for whatever has
          decayed.
        </li>
        <li>At the same check a new spread is sold the same way.</li>
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li>
          {@trade.symbol} falls below {money(@short.strike)}: the loss grows, but only until {money(
            @long.strike
          )}, where the bought put takes over. The most it can lose is {money(@trade.summary.max_loss)}.
        </li>
        <li>
          Nothing is done before 21 days left; then it's closed at whatever it costs. No shares
          are ever bought: that's the point of the spread.
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@trade.symbol} drops"}
          what="spread at expiry"
        />
      </.play_card>
    </div>
    """
  end

  defp playbook(%{trade: %{structure: "iron_condor"}} = assigns) do
    [_long_put, short_put, short_call, _long_call] = Enum.sort_by(assigns.open_legs, & &1.strike)
    pnl = &Legs.at_expiry(assigns.open_legs, &1)

    assigns =
      assign(assigns,
        short_put: short_put,
        short_call: short_call,
        drops: moves(assigns.trade.spot, :down, pnl),
        rises: moves(assigns.trade.spot, :up, pnl)
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li>
          {@trade.symbol} stays between {money(@short_put.strike)} and {money(@short_call.strike)}:
          both spreads lose value every day.
        </li>
        <li>
          At the first daily check the whole condor can be bought back for half the credit, it is: about {money(
            @trade.summary.net / 2
          )} kept. Otherwise it's closed at 21 days.
        </li>
        <li>At the same check a new condor is sold the same way.</li>
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li>
          A big move either way: below {money(@short_put.strike)} or above {money(@short_call.strike)} the loss grows until the bought wing takes over. The most it
          can lose is {money(@trade.summary.max_loss)}.
        </li>
        <li>Nothing is done before 21 days left; then it's closed at whatever it costs.</li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@trade.symbol} drops"}
          what="condor at expiry"
        />
        <.change_table
          :if={@rises != []}
          rows={@rises}
          move={"If #{@trade.symbol} rises"}
          what="condor at expiry"
        />
      </.play_card>
    </div>
    """
  end

  defp playbook(%{trade: %{structure: "long_call"}} = assigns) do
    [call] = assigns.open_legs
    pnl = &Legs.at_expiry(assigns.open_legs, &1)

    assigns =
      assign(assigns,
        call: call,
        paid: call.open_price * Pick.multiplier() * call.quantity,
        rises: moves(assigns.trade.spot, :up, pnl),
        drops: moves(assigns.trade.spot, :down, pnl)
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li :if={@book == "ideas"}>
          {@trade.symbol} bounces off the dip and the call doubles: sold at {money(
            @call.open_price * 2
          )} or more, about {money(@call.open_price * Pick.multiplier())} made.
        </li>
        <li :if={@book == "ideas_half" and @call.quantity > 1}>
          {@trade.symbol} bounces off the dip and the call doubles: half sold at {money(
            @call.open_price * 2
          )} or more, which pays back the {money(@paid)} paid. The rest rides for free.
        </li>
        <li :if={@book == "ideas_half" and @call.quantity == 1}>
          Half is sold and paid back the cost: the trade can't lose money now. The rest rides
          until 21 days or until it falls back to {money(@call.open_price)}.
        </li>
        <.change_table
          :if={@rises != []}
          rows={@rises}
          move={"If #{@trade.symbol} rises"}
          what="call at expiry"
        />
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li :if={@call.quantity > 1 or @book == "ideas"}>
          The dip keeps going and the call halves: sold at {money(@call.open_price / 2)}, about {money(
            @paid / 2
          )} lost.
        </li>
        <li :if={@call.quantity > 1 or @book == "ideas"}>
          Or nothing happens and it decays: sold at 21 days for what's left. The most it can lose
          is the {money(@paid)} paid.
        </li>
        <li :if={@call.quantity == 1 and @book == "ideas_half"}>
          It falls back to {money(@call.open_price)} and the rest is sold there: the gain from the
          half sold is kept.
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@trade.symbol} drops"}
          what="call at expiry"
        />
      </.play_card>
    </div>
    """
  end

  defp playbook(%{trade: %{structure: "long_put"}} = assigns) do
    [put] = assigns.open_legs
    pnl = &Legs.at_expiry(assigns.open_legs, &1)

    assigns =
      assign(assigns,
        put: put,
        paid: put.open_price * Pick.multiplier() * put.quantity,
        drops: moves(assigns.trade.spot, :down, pnl)
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If the market crashes")} /></:title>
        <li :if={@book == "crash_puts"}>
          {@trade.symbol} drops through {money(@put.strike)} and the put gains. It's held to the
          21-day roll and sold there, so the gain lands then.
        </li>
        <li :if={@book == "crash_puts_half" and @put.quantity > 1}>
          {@trade.symbol} drops and the puts double: half are sold at {money(@put.open_price * 2)}, which
          pays back the {money(@paid)} paid. The rest is held to the roll for the bigger move.
        </li>
        <li :if={@book == "crash_puts_half" and @put.quantity == 1}>
          Half is sold and paid back the cost. The rest is held to the 21-day roll, or sold if it
          falls back to {money(@put.open_price)}.
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@trade.symbol} drops"}
          what="put at expiry"
        />
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it stays calm")} /></:title>
        <li>
          The put decays and is sold at 21 days for what's left, and the next month's is bought.
          The difference is what the insurance costs: at most the {money(@paid)} paid this month.
        </li>
      </.play_card>
    </div>
    """
  end

  defp credit?(trade), do: trade.structure in ~w(put_spread iron_condor)

  defp at_stake_words(book) when book in ~w(put_spread iron_condor),
    do: "the most the open trades can lose, set aside as cash"

  defp at_stake_words(_book), do: "the premium paid for the open options"

  # Where an open trade stands against its strikes.
  defp standing(%{spot: spot} = trade) when is_number(spot) do
    legs = Enum.filter(trade.legs, &(&1.status == "open"))
    shorts = Enum.filter(legs, &(&1.side == "short"))

    case {trade.structure, shorts, legs} do
      {_, [_ | _], _} ->
        room = shorts |> Enum.map(&cushion(&1, spot)) |> Enum.min()
        "#{pct(abs(room))} #{if room >= 0, do: "room before", else: "past"} the short strike"

      {"long_call", [], [call]} ->
        "needs #{signed_pct((call.strike + call.open_price) / spot - 1)} to break even"

      {"long_put", [], [put]} ->
        "#{pct(abs(spot - put.strike) / spot)} #{if spot >= put.strike, do: "above", else: "below"} the strike"

      _ ->
        "—"
    end
  end

  defp standing(_trade), do: "—"

  # How far the underlying is from a short strike, positive on the safe side.
  defp cushion(%{kind: "put", strike: strike}, spot), do: (spot - strike) / spot
  defp cushion(%{kind: "call", strike: strike}, spot), do: (strike - spot) / spot

  defp next_decision(%{expiration: nil}), do: "—"

  defp next_decision(%{expiration: expiration}) do
    manage_on = Date.add(expiration, -@manage_dte)

    if Date.before?(Opus.Clock.today(), manage_on),
      do: "#{day(manage_on)} · 21-day check",
      else: "#{day(expiration)} · expiry"
  end

  defp structure_name("put_spread"), do: "put credit spread"
  defp structure_name("iron_condor"), do: "iron condor"
  defp structure_name("long_call"), do: "call"
  defp structure_name("long_put"), do: "put"
  defp structure_name(other), do: other

  defp strikes(%{legs: legs}),
    do:
      legs
      |> Enum.map(& &1.strike)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("/", &strike/1)

  defp limit(nil), do: "unlimited"
  defp limit(value), do: money(value)
end
