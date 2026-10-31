defmodule OpusWeb.Components.PaperBook do
  @moduledoc """
  The Options page's paper books (`Opus.Options.Paper.book/1`): a selector
  across the books, the chosen book's headline numbers, and its
  trades. The other books' trades are drawn by
  `OpusWeb.Components.PaperTrades`; the wheel's are drawn here. In the wheel
  each underlying is one trade: its legs one after another (a put, then
  shares if assigned, then covered calls). The left column lists the trades
  and, for the chosen one, its legs; the right shows the book overview, or
  the chosen trade with one leg in detail and its payoff chart.

  Selection lives in the URL (`?view=paper&book=wheel&trade=SPY&leg=3`),
  handled by `OpusWeb.OptionsLive`.
  """
  use Phoenix.Component
  use OpusWeb, :verified_routes

  import OpusWeb.Copy
  import OpusWeb.Format
  import OpusWeb.PayoffChart
  import OpusWeb.Components.PaperParts

  alias Opus.Options.Paper.{Legs, Pick, Wheel}
  alias OpusWeb.Components.PaperTrades

  # The books, in the order the selector shows them (names: `book_name/1`).
  @books ~w(wheel put_spread iron_condor ideas ideas_half crash_puts crash_puts_half)

  # What each book does.
  defp about("wheel"),
    do:
      copy(
        "The wheel: sell puts, take the shares if assigned, sell calls on them. Paper US$, nothing real."
      )

  defp about("put_spread"),
    do:
      copy(
        "The wheel's put with a cheaper put bought below it: the crash risk capped. Paper US$."
      )

  defp about("iron_condor"),
    do:
      copy("A put spread and a call spread around the price: paid if it goes nowhere. Paper US$.")

  defp about("ideas"),
    do:
      copy(
        "Buys the calls the morning scan flags on dips; sells at double, half, or 21 days. Paper US$."
      )

  defp about("ideas_half"),
    do:
      copy(
        "The same calls, two at a time: half sold at double to pay back the cost, the rest rides. Paper US$."
      )

  defp about("crash_puts"),
    do:
      copy(
        "A SPY put about 10% below the price, rolled monthly: what crash insurance costs. Paper US$."
      )

  defp about("crash_puts_half"),
    do:
      copy(
        "The same crash puts, two at a time: half sold at double, the rest held to the roll. Paper US$."
      )

  attr :current, :string, required: true
  attr :counts, :map, required: true

  defp book_nav(assigns) do
    assigns =
      assign(assigns,
        books: [{"all", copy("All books")} | Enum.map(@books, &{&1, book_name(&1)})]
      )

    ~H"""
    <nav aria-label="Paper books" class="flex flex-wrap gap-1.5">
      <.link
        :for={{key, name} <- @books}
        patch={
          if key == "all", do: ~p"/options?view=paper", else: ~p"/options?view=paper&book=#{key}"
        }
        aria-current={if key == @current, do: "page"}
        class={[
          "inline-flex items-center gap-1.5 rounded-field border px-3 py-1.5 text-[13px] font-medium",
          if(key == @current,
            do: "border-primary text-primary",
            else: "border-base-300 text-muted hover:text-base-content"
          )
        ]}
      >
        <.t {name} />
        <span :if={@counts[key]} class="rounded-full bg-base-300 px-1.5 text-[11px] text-base-content">
          {@counts[key]}
        </span>
      </.link>
    </nav>
    """
  end

  # How long a forward test runs before its numbers say more than luck.
  @judge_after_days 90

  attr :books, :list, required: true
  attr :counts, :map, default: %{}

  @doc """
  The five books side by side: what each has made against just holding its
  underlyings, how long it has run, and what's open. A paper book is a
  forward test, so the page says plainly when it is too early to judge.
  """
  def all_books(assigns) do
    started = Enum.filter(assigns.books, & &1.started_on)

    assigns =
      assign(assigns,
        pnl: Enum.sum_by(started, & &1.pnl),
        value: Enum.sum_by(started, & &1.value),
        open: assigns.counts |> Map.values() |> Enum.sum(),
        priced_at:
          assigns.books
          |> Enum.map(& &1.priced_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(NaiveDateTime, fn -> nil end),
        days:
          started
          |> Enum.map(&Date.diff(Opus.Clock.today(), &1.started_on))
          |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <section
      id="paper-book"
      class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4"
    >
      <.book_nav current="all" counts={@counts} />
      <.priced_at at={@priced_at} />

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.stat label={copy("Value, all books")} value={money(@value)} />
        <.stat
          label={copy("P&L, all books")}
          value={money(@pnl)}
          tone={tone(@pnl)}
        />
        <.stat label={copy("Open trades")} value={to_string(@open)} />
        <.stat label={copy("Running for")} value={"#{@days} days"} />
      </div>

      <p class="text-[13px]">
        <span class="font-medium"><.t {copy("What to take from it:")} /></span>
        {verdict(@days)}
      </p>

      <div class="overflow-x-auto">
        <table class="w-full min-w-[600px] border-collapse text-[13px]">
          <thead>
            <tr class="text-left text-[11px] text-muted">
              <th class="border-b border-base-300 py-2 font-medium">Book</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">P&L</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Return</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">
                Just holding
              </th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Open</th>
              <th class="border-b border-base-300 py-2 pl-2 text-right font-medium">Since</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={book <- @books} class="border-b border-neutral last:border-b-0">
              <td class="py-2">
                <.link
                  patch={~p"/options?view=paper&book=#{book.strategy}"}
                  class="hover:text-primary"
                >
                  <.t {book_name(book.strategy)} />
                </.link>
              </td>
              <%= if book.started_on do %>
                <td class={["px-2 py-2 text-right", tone(book.pnl)]}>{money(book.pnl)}</td>
                <td class={["px-2 py-2 text-right", tone(book.return)]}>
                  {signed_pct(book.return, 2)}
                </td>
                <td class={["px-2 py-2 text-right", tone(book.hold_return)]}>
                  {signed_pct(book.hold_return, 2)}
                </td>
                <td class="px-2 py-2 text-right">{@counts[book.strategy] || 0}</td>
                <td class="py-2 pl-2 text-right text-muted">
                  {Calendar.strftime(book.started_on, "%b %-d")}
                </td>
              <% else %>
                <td colspan="5" class="py-2 pl-2 text-right text-muted">not started</td>
              <% end %>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp verdict(days) when days < @judge_after_days,
    do:
      "Too early to judge: #{days} of the #{@judge_after_days} days a forward test needs. " <>
        "Day-to-day swings here are noise; nothing to change yet. Compare each book's return " <>
        "with just holding once it has run a few months, through at least one market drop."

  defp verdict(_days),
    do:
      "Long enough to compare: a book that trails just holding after this long is paying " <>
        "for its risk without being paid for it. Consider stopping it."

  attr :now, :map, required: true

  # The underlyings' last trades now, beside the snapshot the book was
  # valued at (its last is 15:45 New York, so after the close they differ).
  defp prices_now(assigns) do
    ~H"""
    <p :if={@now != %{}} class="-mt-2 text-[12px] text-muted">
      <span class="font-medium text-base-content">Now (Questrade):</span>
      <span :for={{symbol, %{price: price, at: at}} <- Enum.sort(@now)} class="mr-3">
        {symbol} {money(price)}<span :if={at}> at {clock(at)} {zone_name(at)}</span>
      </span>
    </p>
    """
  end

  # How fresh the prices are: open legs carry their latest quote.
  attr :at, :any, required: true

  defp priced_at(assigns) do
    ~H"""
    <p :if={@at} class="text-[12px] text-muted">
      <.t {copy(
        "Priced at %{time}. Open trades update every 15 minutes while the market is open, and a take-profit fills as soon as a quote reaches it.",
        time: "#{clock(@at)} #{zone_name(@at)}"
      )} />
    </p>
    """
  end

  attr :book, :map, required: true
  attr :counts, :map, default: %{}
  attr :underlyings, :list, default: []
  attr :trade, :map, default: nil
  attr :leg, :map, default: nil
  attr :analysis, :map, default: nil
  attr :now, :map, default: %{}, doc: "underlying → price now (`Opus.Options.Spot.now/1`)"

  def paper_book(assigns) do
    assigns = assign(assigns, about: about(assigns.book.strategy))

    ~H"""
    <section
      id="paper-book"
      class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-200 px-5 py-4"
    >
      <.book_nav current={@book.strategy} counts={@counts} />

      <p class="text-[12px] text-muted"><.t {@about} /></p>
      <.priced_at at={@book.priced_at} />
      <.prices_now now={@now} />

      <p :if={@book.started_on == nil} class="text-[13px] text-muted">
        <.t {copy("Nothing yet: the first trades open at the next 10:30 New York check.")} />
      </p>

      <div :if={@book.started_on} class="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <.stat label={copy("Value")} value={money(@book.value)} />
        <.stat
          label={copy("P&L")}
          value={"#{money(@book.pnl)} · #{signed_pct(@book.return)}"}
          tone={tone(@book.pnl)}
        />
        <.stat
          label={copy("Just holding %{symbols}", symbols: Enum.join(@underlyings, "/"))}
          value={signed_pct(@book.hold_return)}
          tone={tone(@book.hold_return)}
        />
        <.stat
          :if={@book.premium >= 0}
          label={copy("Net premium sold")}
          value={money(@book.premium)}
        />
        <.stat
          :if={@book.premium < 0}
          label={copy("Premium paid")}
          value={money(-@book.premium)}
        />
        <.stat label={copy("This book's cash")} value={money(@book.cash)} />
      </div>
      <p :if={@book.started_on} class="-mt-2 text-[12px] text-muted">
        Each book is its own paper account that started with {money(@book.starting_cash)}, so its
        cash and value are its own, not shared with the other books.
      </p>

      <PaperTrades.body
        :if={@book.strategy != "wheel"}
        now={@now}
        book={@book}
        trade={@trade}
        leg={@leg}
        analysis={@analysis}
      />

      <div
        :if={@book.strategy == "wheel" and @book.trades != []}
        class="grid items-start gap-5 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]"
      >
        <nav aria-label="Trades" class="flex flex-col gap-2">
          <.link
            patch={~p"/options?view=paper&book=wheel"}
            class={[
              "rounded-field px-3 py-2 text-[13px]",
              if(@trade, do: "text-muted hover:text-base-content", else: "bg-base-300 font-medium")
            ]}
          >
            <.t {copy("Overview")} />
          </.link>
          <div :for={trade <- @book.trades} class="flex flex-col">
            <.link
              patch={
                if @trade && @trade.symbol == trade.symbol,
                  do: ~p"/options?view=paper&book=wheel",
                  else: ~p"/options?view=paper&book=wheel&trade=#{trade.symbol}"
              }
              class={[
                "flex flex-col gap-0.5 rounded-field border px-3 py-2",
                if(@trade && @trade.symbol == trade.symbol,
                  do: "border-primary bg-base-300",
                  else: "border-base-300 hover:border-primary"
                )
              ]}
            >
              <span class="flex items-baseline justify-between gap-3">
                <span class="text-[14px] font-medium">{trade.symbol} wheel</span>
                <span class={["text-[14px] font-medium", tone(trade.pnl)]}>{money(trade.pnl)}</span>
              </span>
              <span class="text-[12px] text-muted">{stage_line(trade)}</span>
            </.link>
            <ol
              :if={@trade && @trade.symbol == trade.symbol}
              class="m-0 ml-3 flex list-none flex-col border-l border-base-300 p-0"
            >
              <li :for={leg <- Enum.reverse(trade.legs)}>
                <.link
                  patch={
                    if @leg && @leg.position.id == leg.id,
                      do: ~p"/options?view=paper&book=wheel&trade=#{trade.symbol}",
                      else: ~p"/options?view=paper&book=wheel&trade=#{trade.symbol}&leg=#{leg.id}"
                  }
                  class={[
                    "flex justify-between gap-3 px-3 py-1.5 text-[13px]",
                    if(@leg && @leg.position.id == leg.id,
                      do: "font-medium text-primary",
                      else: "text-muted hover:text-base-content"
                    )
                  ]}
                >
                  <span>{leg_name(leg)}</span>
                  <span>{leg.status}</span>
                </.link>
              </li>
            </ol>
          </div>
        </nav>

        <div class="min-w-0">
          <.overview :if={@trade == nil} book={@book} />
          <.trade_panel :if={@trade} trade={@trade} leg={@leg} analysis={@analysis} />
        </div>
      </div>
    </section>
    """
  end

  # Every trade side by side: what it holds, how much room it has before the
  # strike, the next date the rules act on it, and its P&L.
  attr :book, :map, required: true

  defp overview(assigns) do
    reserved =
      assigns.book.trades
      |> Enum.filter(&match?(%{short: %{kind: "put"}}, &1))
      |> Enum.sum_by(&(&1.short.strike * Wheel.multiplier() * &1.short.quantity))

    assigns = assign(assigns, reserved: reserved)

    ~H"""
    <section aria-label="Book overview" class="flex flex-col gap-4">
      <p class="text-[13px] text-muted">
        {length(@book.trades)} trades, one wheel per underlying. Puts are cash-secured: {money(
          @reserved
        )} of the {money(@book.cash)} cash is set aside in case they are assigned.
        Pick a trade for its legs and payoff.
      </p>
      <table class="w-full border-collapse text-[13px]">
        <thead>
          <tr class="text-left text-[11px] text-muted">
            <th class="border-b border-base-300 py-2 font-medium">Trade</th>
            <th class="border-b border-base-300 px-2 py-2 font-medium">Room before the strike</th>
            <th class="border-b border-base-300 px-2 py-2 font-medium">Next decision</th>
            <th class="border-b border-base-300 py-2 pl-2 text-right font-medium">P&L</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={trade <- @book.trades} class="border-b border-neutral last:border-b-0">
            <td class="py-2">
              <.link
                patch={~p"/options?view=paper&book=wheel&trade=#{trade.symbol}"}
                class="hover:text-primary"
              >
                <span class="font-medium">{trade.symbol}</span>
                <span class="text-muted">{stage_word(trade.stage)}</span>
              </.link>
            </td>
            <td class="px-2 py-2"><.room trade={trade} /></td>
            <td class="px-2 py-2 text-muted">{next_decision(trade)}</td>
            <td class={["py-2 pl-2 text-right", tone(trade.pnl)]}>{money(trade.pnl)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  # How far the underlying is from the short leg's strike, on the side where
  # the leg expires worthless, as a bar out to 10%.
  attr :trade, :map, required: true

  defp room(%{trade: %{short: %{} = short, spot: spot}} = assigns) when is_number(spot) do
    assigns = assign(assigns, cushion: cushion(short, spot))

    ~H"""
    <span class="flex items-center gap-2">
      <span class="h-1.5 w-20 overflow-hidden rounded-full bg-base-300" aria-hidden="true">
        <span
          class={["block h-full", if(@cushion > 0, do: "bg-success", else: "bg-error")]}
          style={"width: #{min(abs(@cushion) / 0.10, 1) * 100}%"}
        />
      </span>
      <span class={if @cushion < 0, do: "text-error"}>
        {pct(abs(@cushion))} {side_word(@trade.short, @cushion)}
      </span>
    </span>
    """
  end

  defp room(assigns) do
    ~H"""
    <span class="text-muted">—</span>
    """
  end

  # One trade: what the whole cycle has made so far, then one leg in detail.
  attr :trade, :map, required: true
  attr :leg, :map, default: nil
  attr :analysis, :map, default: nil

  defp trade_panel(assigns) do
    ~H"""
    <section aria-label={"#{@trade.symbol} trade"} class="flex flex-col gap-4">
      <div class="flex flex-col gap-2 rounded-box border border-base-300 px-4 py-3">
        <span class="text-[15px] font-semibold">
          {@trade.symbol} wheel
          <span class="font-normal text-muted">· {stage_word(@trade.stage)}</span>
        </span>
        <div class="grid grid-cols-3 gap-3">
          <.fact label="Premium collected" value={money(@trade.premium)} />
          <.fact label="Trade P&L" value={money(@trade.pnl)} tone={tone(@trade.pnl)} />
          <.fact label="Legs so far" value={to_string(length(@trade.legs))} />
        </div>
      </div>
      <.leg_detail
        :if={@leg}
        leg={@leg}
        analysis={@analysis}
        cost_basis={@trade.shares && @trade.shares.open_price}
      />
    </section>
    """
  end

  attr :leg, :map, required: true
  attr :analysis, :map, default: nil
  attr :cost_basis, :float, default: nil

  defp leg_detail(%{leg: %{position: %{kind: "shares"}}} = assigns) do
    assigns = assign(assigns, now: now_spot(assigns.leg))

    ~H"""
    <section aria-label="Leg detail" class="flex flex-col gap-3">
      <span class="text-[15px] font-semibold">
        {@leg.position.quantity} {@leg.position.symbol}
        <.t {copy("shares from an assignment")} />
      </span>
      <p class="text-[13px] text-muted">
        Bought at {money(@leg.position.open_price)} a share on {day(@leg.position.opened_on)}, when a
        put finished in the money. The wheel sells covered calls against them at or above that
        price until they are called away.
      </p>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <.fact label="Cost" value={money(@leg.position.open_price * @leg.position.quantity)} />
        <.fact label={"#{@leg.position.symbol} now"} value={money(@now)} />
        <.fact
          label="P&L"
          value={@now && money((@now - @leg.position.open_price) * @leg.position.quantity)}
        />
      </div>
      <.playbook :if={@leg.position.status == "open"} p={@leg.position} now={@now} />
    </section>
    """
  end

  defp leg_detail(assigns) do
    %{position: p, events: events, quote: quote} = assigns.leg
    opened = Enum.find(events, &(&1.kind == "open"))
    now = now_spot(assigns.leg)
    open? = p.status == "open"

    # The latest quote's mid, like the book's overview; the nightly mark only
    # when there's no quote. A closed leg is worth what it closed at.
    mark = if open?, do: Pick.mid(quote) || last_mark(assigns.leg), else: p.close_price

    assigns =
      assign(assigns,
        p: p,
        quote: quote,
        spot_then: opened && opened.detail["spot"],
        now: now,
        mark: mark,
        premium: p.open_price * Wheel.multiplier() * p.quantity,
        pnl:
          if(open?,
            do: mark && (p.open_price - mark) * Wheel.multiplier() * p.quantity,
            else: Legs.realized(p)
          ),
        kept: mark && (p.open_price - mark) / p.open_price,
        days_left: Date.diff(p.expiration, Opus.Clock.today()),
        cushion: now && cushion(p, now),
        outcome: Enum.find(events, &(&1.kind != "open"))
      )

    ~H"""
    <section aria-label="Leg detail" class="flex flex-col gap-4">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class="text-[15px] font-semibold">
          {@p.symbol} {money(@p.strike)} {@p.kind}
          <span class="font-normal text-muted">· {day(@p.expiration)}</span>
        </span>
        <span class="text-[13px] text-muted">
          {if @p.status == "open", do: "#{@days_left} days left", else: @p.status}
        </span>
      </div>

      <p class="text-[13px] text-muted">{sold_line(@p, @premium, @spot_then)}</p>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.fact
          label={if @p.status == "open", do: "Option worth now", else: "Closed at"}
          value={money(@mark)}
          note={@quote && "bid #{num(@quote.bid)} · ask #{num(@quote.ask)}"}
        />
        <.fact label="P&L" value={money(@pnl)} note={kept_note(@kept)} tone={tone(@pnl)} />
        <.fact
          label={"#{@p.symbol} now"}
          value={money(@now)}
          note={@cushion && "#{pct(abs(@cushion))} #{side_word(@p, @cushion)} the strike"}
        />
        <.fact
          label="Chance it ends in the money (≈ delta)"
          value={@quote && @quote.delta && pct(abs(@quote.delta))}
          note={@quote && @quote.iv_pct && "implied vol #{num(@quote.iv_pct, 1)}%"}
        />
      </div>

      <div :if={@p.status == "open"} class="flex flex-col gap-1.5">
        <span class="text-[13px] font-medium">
          <.t {copy("What happens next")} />
        </span>
        <ol class="m-0 flex list-none flex-col gap-1.5 p-0 text-[13px]">
          <li>
            <span class="font-medium">Any day:</span>
            bought back if it can be bought for {money(@leg.take_profit_price)} or less, keeping about {money(
              @premium / 2
            )}.
          </li>
          <li>
            <span class="font-medium">{day(@leg.manage_on)} (21 days left):</span>
            closed if {@p.symbol} is {safe_word(@p)} {money(@p.strike)}; held to expiry if not.
          </li>
          <li>
            <span class="font-medium">{day(@p.expiration)} (expiry):</span>
            <.expiry_words p={@p} premium={@premium} />
          </li>
        </ol>
      </div>

      <.playbook
        :if={@p.status == "open"}
        p={@p}
        now={@now}
        premium={@premium}
        take_profit={@leg.take_profit_price}
        manage_on={@leg.manage_on}
        cost_basis={@cost_basis}
      />

      <p :if={@outcome} class="text-[13px]">
        {outcome_words(@outcome.kind)} on {day(@outcome.on)}: {money(@outcome.cash)}.
      </p>

      <div :if={@p.status == "open"} class="flex flex-col gap-1">
        <span class="text-[12px] text-muted">
          P&L by {@p.symbol} price, today and at expiry. The flat part is the premium kept; below
          the break-even the leg loses money.
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

  # What happens, and what to do, if the leg goes well or goes wrong: the
  # wheel's rules as numbered steps with this leg's numbers, plus what a drop
  # of 5%, 10%, 20% and a Covid-size 34% from today would cost at expiry.
  # The same steps are what a person would do by hand at the broker.
  attr :p, :map, required: true
  attr :now, :float, default: nil
  attr :premium, :float, default: nil
  attr :take_profit, :float, default: nil
  attr :manage_on, :any, default: nil
  attr :cost_basis, :float, default: nil

  defp playbook(%{p: %{kind: "put"}} = assigns) do
    assigns = assign(assigns, drops: drops(assigns.now, &put_at_expiry(assigns.p, &1)))

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li>
          {@p.symbol} stays above {money(@p.strike)} or rises, and the put loses value every day.
        </li>
        <li>
          At the first daily check it can be bought back for {money(@take_profit)} or less, it is: buy to
          close 1 {@p.symbol} {day(@p.expiration)} {num(@p.strike)} put, limit {money(@take_profit)}. About {money(
            @premium - @take_profit * 100 - 0.2
          )} kept after fees.
        </li>
        <li>
          If that hasn't happened by {day(@manage_on)} and {@p.symbol} is still above {money(
            @p.strike
          )}, it's bought back then at the ask, keeping whatever has decayed.
        </li>
        <li>At the same check a new put is sold the same way: 30–45 days, delta near −0.25.</li>
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li>
          {@p.symbol} falls toward {money(@p.strike)}. The put gains value, so the paper P&L goes
          red. Nothing is done: there is no stop-loss and no rolling in this version. Closing in a
          panic would break the test.
        </li>
        <li>
          Still below {money(@p.strike)} on {day(@manage_on)}: held to expiry rather than closed at a
          loss.
        </li>
        <li>
          Below {money(@p.strike)} at expiry: assigned. The broker does this on its own; 100 {@p.symbol} shares arrive at {money(
            @p.strike
          )} ({money(@p.strike * 100)} of cash), an
          effective cost of {money(@p.strike - @p.open_price)}.
        </li>
        <li>
          Then sell a covered call each month at or above {money(@p.strike)} and collect its
          premium until the shares are called away. Shares are never sold at a loss; that can take
          months (2022's bear took about two years to recover).
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@p.symbol} drops"}
          what="put at expiry"
        />
      </.play_card>
    </div>
    """
  end

  defp playbook(%{p: %{kind: "call"}} = assigns) do
    assigns =
      assign(assigns,
        drops: drops(assigns.now, &call_at_expiry(assigns.p, assigns.cost_basis, &1))
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li>
          {@p.symbol} stays below {money(@p.strike)}: the call loses value and is bought back for {money(
            @take_profit
          )} or less (or closed on {day(@manage_on)}), and the next call is sold.
        </li>
        <li>
          {@p.symbol} ends above {money(@p.strike)}: the shares are called away at {money(@p.strike)}<span :if={
            @cost_basis
          }>, {money((@p.strike - @cost_basis) * 100)} more than they cost</span>,
          plus every premium collected. At the same check a new put starts the cycle again.
        </li>
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li>
          {@p.symbol} keeps falling. The call expires worthless and its {money(@premium)} is kept,
          but the shares lose more than that.
        </li>
        <li>
          Keep selling calls at or above the shares' cost. Premiums get smaller the further the
          price falls below it, and the shares are never sold at a loss.
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@p.symbol} drops"}
          what="shares and call at expiry"
        />
      </.play_card>
    </div>
    """
  end

  defp playbook(%{p: %{kind: "shares"}} = assigns) do
    assigns =
      assign(assigns,
        drops: drops(assigns.now, &((&1 - assigns.p.open_price) * assigns.p.quantity))
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.play_card tone="success">
        <:title><.t {copy("If it goes well")} /></:title>
        <li>
          {@p.symbol} recovers above {money(@p.open_price)}: the next covered call gets called away
          at or above cost, and the cycle starts again with a new put.
        </li>
      </.play_card>
      <.play_card tone="error">
        <:title><.t {copy("If it goes wrong")} /></:title>
        <li>
          {@p.symbol} stays below {money(@p.open_price)}: hold, and keep selling monthly calls at
          or above cost. Never sell the shares at a loss.
        </li>
        <.change_table
          :if={@drops != []}
          rows={@drops}
          move={"If #{@p.symbol} drops"}
          what="the shares"
        />
      </.play_card>
    </div>
    """
  end

  defp drops(now, pnl), do: moves(now, :down, pnl)

  # A short put held to expiry: premium kept less the strike's shortfall.
  defp put_at_expiry(p, price),
    do: (p.open_price - max(p.strike - price, 0)) * Wheel.multiplier() * p.quantity

  # Shares plus their short call held to expiry: the shares' change from cost
  # (capped at the strike, where they are called away) plus the premium.
  defp call_at_expiry(_p, nil, _price), do: nil

  defp call_at_expiry(p, cost, price),
    do: (min(price, p.strike) - cost + p.open_price) * Wheel.multiplier() * p.quantity

  attr :p, :map, required: true
  attr :premium, :float, required: true

  defp expiry_words(%{p: %{kind: "put"}} = assigns) do
    ~H"""
    if {@p.symbol} is above {money(@p.strike)} it expires worthless and the {money(@premium)} is kept. Below it, the book buys 100 shares at {money(
      @p.strike
    )} ({money(@p.strike * 100)}), an effective cost of {money(@p.strike - @p.open_price)} after
    the premium.
    """
  end

  defp expiry_words(assigns) do
    ~H"""
    if {@p.symbol} is above {money(@p.strike)} the shares are sold at {money(@p.strike)} (called away) and the cycle starts again with a new put. Below it, the call expires,
    the {money(@premium)} is kept, and a new call is sold.
    """
  end

  defp stage_word(:waiting), do: "· waiting to sell a put"
  defp stage_word(:short_put), do: "· selling a put"
  defp stage_word(:holding_shares), do: "· holding assigned shares"
  defp stage_word(:covered_call), do: "· shares with a covered call"

  defp stage_line(%{short: %{} = short} = trade) do
    room =
      if is_number(trade.spot),
        do:
          " · #{pct(abs(cushion(short, trade.spot)))} #{side_word(short, cushion(short, trade.spot))}",
        else: ""

    "#{money(short.strike)} #{short.kind} · #{day(short.expiration)}#{room}"
  end

  defp stage_line(trade), do: String.trim_leading(stage_word(trade.stage), "· ")

  defp next_decision(%{short: %{} = short}) do
    manage_on = Wheel.manage_on(short)

    if Date.before?(Opus.Clock.today(), manage_on),
      do: "#{day(manage_on)} · 21-day check",
      else: "#{day(short.expiration)} · expiry"
  end

  defp next_decision(_trade), do: "—"

  defp leg_name(%{kind: "shares"} = p), do: "#{p.quantity} shares at #{money(p.open_price)}"
  defp leg_name(p), do: "#{money(p.strike)} #{p.kind} · #{day(p.expiration)}"

  defp kept_note(nil), do: nil
  defp kept_note(kept) when kept < 0, do: "down #{pct(-kept)} of the premium so far"
  defp kept_note(kept), do: "#{pct(kept)} of the premium kept"

  defp sold_line(p, premium, nil),
    do: "Sold on #{day(p.opened_on)} for #{money(p.open_price)} a share, #{money(premium)} in."

  defp sold_line(p, premium, spot) do
    c = cushion(p, spot)

    "Sold on #{day(p.opened_on)} for #{money(p.open_price)} a share, #{money(premium)} in, " <>
      "with #{p.symbol} at #{money(spot)} (#{pct(abs(c))} #{side_word(p, c)} the strike)."
  end

  defp now_spot(%{quote: %{spot: spot}}) when is_number(spot), do: spot
  defp now_spot(%{marks: marks}), do: marks |> List.last() |> then(&(&1 && &1.spot))

  defp last_mark(%{marks: marks}), do: marks |> Enum.reverse() |> Enum.find_value(& &1.mid)

  # How far the underlying is from the strike as a share of its price:
  # positive on the side where the short leg expires worthless.
  defp cushion(%{kind: "put", strike: strike}, spot), do: (spot - strike) / spot
  defp cushion(%{kind: "call", strike: strike}, spot), do: (strike - spot) / spot

  defp side_word(%{kind: "put"}, cushion) when cushion >= 0, do: "above"
  defp side_word(%{kind: "put"}, _cushion), do: "below"
  defp side_word(%{kind: "call"}, cushion) when cushion >= 0, do: "below"
  defp side_word(%{kind: "call"}, _cushion), do: "above"

  defp safe_word(%{kind: "put"}), do: "above"
  defp safe_word(%{kind: "call"}), do: "below"

  defp outcome_words("close"), do: "Bought back"
  defp outcome_words("expire"), do: "Expired worthless"
  defp outcome_words("assign"), do: "Assigned 100 shares"
  defp outcome_words("call_away"), do: "Called away"
end
