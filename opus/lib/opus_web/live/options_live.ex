defmodule OpusWeb.OptionsLive do
  @moduledoc """
  Options page: describe one single-leg position and see, in plain words,
  what happens at expiry if it is assigned, expires worthless, or pays off,
  with the numbers that matter alongside.

  The math comes from the Rust engine (`Opus.Options`); this module only
  collects the inputs and explains the result.
  """
  use OpusWeb, :live_view

  import OpusWeb.Format
  import OpusWeb.PayoffChart

  alias Opus.Auro.Client
  alias Opus.Options
  alias Opus.Options.Idea
  alias Opus.Options.Paper
  alias Opus.Options.Spot
  alias OpusWeb.Components.PaperBook

  @defaults %{
    "underlying" => "SPY",
    "strategy" => "cash_secured_put",
    "strike" => "",
    "expiration" => "",
    "premium" => "",
    "contracts" => "1",
    "spot" => "",
    "sigma" => "",
    "cost_basis" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    # A scan that finishes while the page is open replaces the ideas.
    if connected?(socket), do: Options.subscribe_ideas()

    {:ok,
     socket
     |> assign(
       page_title: "Options",
       form: to_form(@defaults, as: :position),
       params: @defaults,
       analysis: nil,
       error: nil,
       busy: false,
       pane: "position",
       filter: "all",
       view: "workbench",
       trade: nil,
       leg: nil,
       paper_analysis: nil,
       paper_underlyings: [],
       quotes: %{expiries: [], rows: []}
     )
     |> assign_chain(nil, nil)
     |> assign_ideas()
     |> assign(
       paper: nil,
       all_books: [],
       paper_counts: Paper.open_counts(),
       paper_pnl: Paper.total_pnl()
     )}
  end

  # Three views behind tabs, each with its own URL so they can be
  # bookmarked: `/options` (or `?view=paper`) the paper books, which open
  # first, `?view=workbench` the workbench and `?view=custom` a contract
  # typed by hand. On the books `&book=` picks a book (all
  # five side by side by default), `&trade=` one of its trades (the wheel's
  # by underlying, the others' by id) and `&leg=` one of its legs.
  @impl true
  def handle_params(%{"view" => "paper"} = params, _uri, socket) do
    if params["book"] in Paper.books(),
      do: book_params(params, socket),
      else: all_books_params(socket)
  end

  def handle_params(%{"view" => "workbench"}, _uri, socket),
    do: {:noreply, assign(socket, view: "workbench")}

  def handle_params(%{"view" => "custom"}, _uri, socket) do
    params = socket.assigns.params
    {:noreply, socket |> assign(view: "custom") |> fill_from_chain(params, params)}
  end

  def handle_params(_params, _uri, socket), do: all_books_params(socket)

  defp all_books_params(socket) do
    {:noreply,
     assign(socket,
       view: "paper",
       paper: nil,
       all_books: Enum.map(Paper.books(), &Paper.book/1),
       paper_counts: Paper.open_counts(),
       paper_pnl: Paper.total_pnl(),
       trade: nil,
       leg: nil,
       paper_analysis: nil
     )}
  end

  defp book_params(params, socket) do
    book = params["book"]
    paper = Paper.book(book)
    {trade, leg, analysis} = paper_selection(book, paper, params)

    underlyings = paper_underlyings(book, paper)

    {:noreply,
     socket
     |> assign(
       view: "paper",
       paper: paper,
       paper_counts: Paper.open_counts(),
       paper_pnl: Paper.total_pnl(),
       paper_underlyings: underlyings,
       trade: trade,
       leg: leg,
       paper_analysis: analysis
     )
     |> assign_new(:spot_now, fn -> %{} end)
     |> start_async(:spot_now, fn -> Spot.now(underlyings) end)}
  end

  defp paper_selection("wheel", paper, params) do
    trade = Enum.find(paper.trades, &(&1.symbol == params["trade"]))
    leg = trade && trade_leg(trade, params["leg"])
    {trade, leg, leg && payoff(leg, trade)}
  end

  defp paper_selection(_book, paper, params) do
    trade = Enum.find(paper.trades, &(to_string(&1.id) == params["trade"]))
    leg = trade && Enum.find(trade.legs, &(to_string(&1.id) == params["leg"]))
    {trade, leg && Paper.leg(leg.id), trade && structure_payoff(trade)}
  end

  # The book's underlyings for its buy-and-hold comparison: those it has
  # traded, or those it is configured for before its first trade.
  defp paper_underlyings(book, %{trades: []}), do: Paper.underlyings(book)

  defp paper_underlyings(_book, %{trades: trades}),
    do: trades |> Enum.map(& &1.symbol) |> Enum.uniq() |> Enum.sort()

  # The leg asked for if it belongs to the trade, else the trade's current
  # one: its open short leg, its shares, or its latest leg.
  defp trade_leg(trade, id) do
    chosen =
      with id when is_binary(id) <- id,
           {id, ""} <- Integer.parse(id) do
        Enum.find(trade.legs, &(&1.id == id))
      else
        _ -> nil
      end

    case chosen || trade.short || trade.shares || List.last(trade.legs) do
      nil -> nil
      position -> Paper.leg(position.id)
    end
  end

  # The workbench's payoff curves for an open wheel leg; nil when the leg is
  # closed or the engine can't be reached.
  defp payoff(%{position: %{status: "open", kind: kind}} = leg, trade)
       when kind in ~w(put call) do
    cost_basis = trade.shares && trade.shares.open_price

    case Options.scenarios(Paper.scenario_params(leg, cost_basis)) do
      {:ok, analysis} -> analysis
      {:error, _reason} -> nil
    end
  end

  defp payoff(_leg, _trade), do: nil

  # The engine's curves for a whole open trade, its legs added together.
  defp structure_payoff(%{status: "open"} = trade) do
    case Options.structure_scenarios(Paper.structure_request(trade)) do
      {:ok, analysis} -> analysis
      {:error, _reason} -> nil
    end
  end

  defp structure_payoff(_trade), do: nil

  defp assign_ideas(socket) do
    {scanned_on, ideas} = Options.latest_ideas()
    assign(socket, ideas: ideas, ideas_scanned_on: scanned_on)
  end

  # The stored chain to pick from: the chosen underlying's expiries and the
  # strikes of the current strategy's kind at the chosen expiry.
  defp assign_chain(socket, underlying, expiration) do
    underlyings = Options.underlyings()
    underlying = underlying || List.first(Enum.map(underlyings, & &1.symbol))
    expiries = if underlying, do: Options.expiries(underlying), else: []
    expiration = if expiration in expiries, do: expiration, else: List.first(expiries)
    kind = Options.kind(socket.assigns.params["strategy"])
    rows = if underlying && expiration, do: Options.chain(underlying, expiration, kind), else: []

    assign(socket,
      chain: %{
        underlyings: underlyings,
        underlying: underlying,
        expiries: expiries,
        expiration: expiration,
        kind: kind,
        rows: rows,
        spot: rows |> List.first() |> then(&(&1 && &1.spot)),
        captured_at: rows |> List.first() |> then(&(&1 && &1.captured_at))
      }
    )
  end

  @impl true
  def handle_event("change", %{"position" => params}, %{assigns: %{view: "custom"}} = socket) do
    %{params: old, chain: chain} = socket.assigns

    {:noreply,
     socket
     |> fill_from_chain(old, Map.merge(old, params))
     |> assign_chain(chain.underlying, chain.expiration)}
  end

  def handle_event("change", %{"position" => params}, socket) do
    params = Map.merge(socket.assigns.params, params)
    socket = assign(socket, params: params, form: to_form(params, as: :position))

    # A new strategy may trade the other kind, so the picker follows it.
    {:noreply,
     assign_chain(socket, socket.assigns.chain.underlying, socket.assigns.chain.expiration)}
  end

  def handle_event("chain", %{"chain" => %{"underlying" => underlying} = chain}, socket) do
    expiration =
      if underlying == socket.assigns.chain.underlying,
        do: parse_date(chain["expiration"]),
        else: nil

    # The kind picker changes the strategy's kind and keeps its side.
    socket =
      case chain["kind"] do
        kind when kind in ["call", "put"] ->
          put_strategy(
            socket,
            Options.strategy_for(Options.side(socket.assigns.params["strategy"]), kind)
          )

        _ ->
          socket
      end

    {:noreply, assign_chain(socket, underlying, expiration)}
  end

  def handle_event("pane", %{"pane" => pane}, socket) when pane in ["ideas", "chain", "position"],
    do: {:noreply, assign(socket, pane: pane)}

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  # Flip buy ↔ sell for the same kind and re-run with the matching side of the quote.
  def handle_event("side", _params, socket) do
    %{params: params, chain: chain} = socket.assigns
    side = if Options.side(params["strategy"]) == :buy, do: :sell, else: :buy
    strategy = Options.strategy_for(side, Options.kind(params["strategy"]))

    same_chain = chain.underlying == params["underlying"]

    premium =
      case Enum.find(chain.rows, &(plain(&1.strike) == params["strike"])) do
        %{bid: bid, ask: ask} when same_chain -> plain(if side == :sell, do: bid, else: ask)
        _ -> params["premium"]
      end

    params = Map.merge(params, %{"strategy" => strategy, "premium" => premium})
    socket = assign(socket, params: params, form: to_form(params, as: :position))
    handle_event("analyze", %{"position" => params}, socket)
  end

  def handle_event("idea", %{"id" => id}, socket) do
    %Idea{} = idea = Enum.find(socket.assigns.ideas, &(to_string(&1.id) == id))

    params =
      Map.merge(socket.assigns.params, %{
        "underlying" => idea.symbol,
        "strategy" => if(idea.kind == "put", do: "long_put", else: "long_call"),
        "strike" => plain(idea.strike),
        "expiration" => Date.to_iso8601(idea.expiration),
        "premium" => plain(idea.ask),
        "spot" => plain(idea.spot),
        "sigma" => plain(idea.iv_pct)
      })

    socket =
      assign(socket, params: params, form: to_form(params, as: :position), pane: "position")

    handle_event("analyze", %{"position" => params}, socket)
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    case Options.set_idea_status(id, "dismissed") do
      {:ok, _} ->
        {:noreply, assign_ideas(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The scan ran again and replaced that list, so the idea wasn't dismissed. " <>
             "The fresh list is showing now; dismiss it again if it is still there."
         )
         |> assign_ideas()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update that idea.")}
    end
  end

  def handle_event("use", %{"strike" => strike}, socket) do
    %{chain: chain, params: params} = socket.assigns
    row = Enum.find(chain.rows, &(plain(&1.strike) == strike))
    premium = if Options.side(params["strategy"]) == :sell, do: row.bid, else: row.ask

    params =
      Map.merge(params, %{
        "underlying" => chain.underlying,
        "strike" => plain(row.strike),
        "expiration" => Date.to_iso8601(chain.expiration),
        "premium" => plain(premium),
        "spot" => plain(row.spot),
        "sigma" => plain(row.volatility)
      })

    socket =
      assign(socket, params: params, form: to_form(params, as: :position), pane: "position")

    handle_event("analyze", %{"position" => params}, socket)
  end

  def handle_event("analyze", %{"position" => params}, socket) do
    params = Map.merge(socket.assigns.params, params)
    socket = assign(socket, params: params, form: to_form(params, as: :position), busy: true)

    case Options.scenarios(params) do
      {:ok, analysis} -> {:noreply, assign(socket, analysis: analysis, error: nil, busy: false)}
      {:error, reason} -> {:noreply, assign(socket, error: describe(reason), busy: false)}
    end
  end

  @impl true
  def handle_info({:ideas_updated, _scanned_on}, socket), do: {:noreply, assign_ideas(socket)}

  # The underlyings' prices now (Questrade), asked for when a book opens.
  @impl true
  def handle_async(:spot_now, {:ok, now}, socket), do: {:noreply, assign(socket, spot_now: now)}
  def handle_async(:spot_now, _failed, socket), do: {:noreply, socket}

  # The contract tab picks from the stored chain when its underlying has
  # one: the expiry and strike come from the snapshot, and a newly picked
  # contract (another underlying, strategy, expiry or strike) brings its
  # quote along: the bid when selling, the ask when buying, with the spot
  # and implied vol. A premium typed over that is kept until the contract
  # changes. An underlying with no stored chain is typed by hand.
  @contract_keys ~w(underlying strategy expiration strike)

  defp fill_from_chain(socket, old, params) do
    symbol = params["underlying"] |> to_string() |> String.trim() |> String.upcase()
    expiries = if symbol == "", do: [], else: Options.expiries(symbol)

    params =
      cond do
        expiries != [] -> pick_contract(old, Map.put(params, "underlying", symbol), expiries)
        params["underlying"] == old["underlying"] -> params
        # Another underlying with nothing stored: the old one's numbers don't apply.
        true -> Map.merge(params, Map.new(~w(strike expiration premium spot sigma), &{&1, ""}))
      end

    rows =
      case parse_date(params["expiration"]) do
        nil ->
          []

        date ->
          if date in expiries,
            do: Options.chain(symbol, date, Options.kind(params["strategy"])),
            else: []
      end

    assign(socket,
      params: params,
      form: to_form(params, as: :position),
      quotes: %{expiries: expiries, rows: rows}
    )
  end

  defp pick_contract(old, params, expiries) do
    expiration = parse_date(params["expiration"])
    expiration = if expiration in expiries, do: expiration, else: hd(expiries)
    params = Map.put(params, "expiration", Date.to_iso8601(expiration))

    rows =
      Options.chain(params["underlying"], expiration, Options.kind(params["strategy"]),
        each_side: :all
      )

    row = Enum.find(rows, &(plain(&1.strike) == params["strike"]))

    cond do
      rows == [] ->
        params

      row && Map.take(old, @contract_keys) == Map.take(params, @contract_keys) ->
        params

      true ->
        row = row || Enum.find(rows, & &1.at_the_money)
        premium = if Options.side(params["strategy"]) == :sell, do: row.bid, else: row.ask

        Map.merge(params, %{
          "strike" => plain(row.strike),
          "premium" => plain(premium),
          "spot" => plain(row.spot),
          "sigma" => plain(row.volatility)
        })
    end
  end

  defp put_strategy(socket, strategy) do
    params = Map.put(socket.assigns.params, "strategy", strategy)
    assign(socket, params: params, form: to_form(params, as: :position))
  end

  defp describe(message) when is_binary(message), do: message
  defp describe(reason), do: Client.describe_error(reason)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp expiry_option(date),
    do: "#{Calendar.strftime(date, "%b %-d, %Y")} · #{Date.diff(date, Opus.Clock.today())}d"

  defp strike_option(%{at_the_money: true} = row), do: "#{plain(row.strike)} · at the money"
  defp strike_option(row), do: plain(row.strike)

  defp picked_quote(rows, params), do: Enum.find(rows, &(plain(&1.strike) == params["strike"]))

  # A number the way a person would type it into the form.
  defp plain(nil), do: ""

  defp plain(value) when is_float(value) and value == trunc(value),
    do: Integer.to_string(trunc(value))

  defp plain(value) when is_float(value), do: value |> Float.round(2) |> Float.to_string()
  defp plain(value), do: to_string(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-5">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <div class="flex flex-wrap items-baseline gap-3">
            <h1 class="text-[22px] font-semibold tracking-tight">
              <.t {copy("Options")} />
            </h1>
            <span class="text-[13px] text-muted">
              <.t {scan_line(@ideas_scanned_on, @ideas, @chain)} />
            </span>
          </div>
          <span class="text-[13px] text-muted">
            <.t {copy("Nothing here places a trade.")} />
          </span>
        </header>

        <nav aria-label="Options views" class="flex gap-1 border-b border-base-300">
          <.view_tab view="paper" current={@view} path={~p"/options"}>
            <.t {copy("Paper book")} />
            <span
              :if={@paper_counts != %{}}
              title={open_words(@paper_counts |> Map.values() |> Enum.sum())}
              class={[
                "rounded-full px-1.5 text-[11px] font-medium tabular-nums",
                if(@paper_pnl >= 0, do: "bg-success/15 text-success", else: "bg-error/15 text-error")
              ]}
            >
              {signed_money(@paper_pnl)}
            </span>
          </.view_tab>
          <.view_tab view="workbench" current={@view} path={~p"/options?view=workbench"}>
            <.t {copy("Workbench")} />
          </.view_tab>
          <.view_tab view="custom" current={@view} path={~p"/options?view=custom"}>
            <.t {copy("Your own contract")} />
          </.view_tab>
        </nav>

        <p
          :if={@error && @view in ["workbench", "custom"]}
          role="alert"
          class="rounded-box border border-error/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@error}
        </p>

        <div
          :if={@view == "workbench"}
          role="group"
          aria-label="Section"
          class="grid grid-cols-3 gap-1 rounded-field border border-base-300 bg-base-200 p-1 sm:hidden"
        >
          <button
            :for={
              {pane, label} <- [
                {"ideas", copy("Ideas")},
                {"chain", copy("Chain")},
                {"position", copy("Position")}
              ]
            }
            type="button"
            phx-click="pane"
            phx-value-pane={pane}
            aria-pressed={to_string(pane == @pane)}
            class={[
              "min-h-10 rounded-field text-[14px]",
              if(pane == @pane, do: "bg-base-300 font-medium", else: "text-muted")
            ]}
          >
            <.t {label} />
          </button>
        </div>

        <div :if={@view == "workbench"} class="flex flex-wrap items-start gap-5">
          <aside
            aria-label="Pick a contract"
            class="flex w-full min-w-0 flex-col gap-4 sm:w-[420px] sm:flex-none"
          >
            <.ideas_box
              ideas={@ideas}
              scanned_on={@ideas_scanned_on}
              filter={@filter}
              params={@params}
              class={pane_class(@pane, "ideas")}
            />
            <.chain_box chain={@chain} params={@params} class={pane_class(@pane, "chain")} />
          </aside>

          <section
            aria-label="Position"
            class={["min-w-0 flex-[999_1_520px] flex-col gap-4", pane_class(@pane, "position")]}
          >
            <%= if @analysis do %>
              <.position analysis={@analysis} params={@params} form={@form} busy={@busy} />
            <% else %>
              <div class="flex flex-col gap-2 rounded-box border border-base-300 bg-base-200 px-5 py-4">
                <span class="text-[15px] font-semibold"><.t {copy("Pick a contract")} /></span>
                <p class="text-[13px] text-muted">
                  Choose an idea or a strike from the chain and the position shows up here: what you pay,
                  the payoff by price, and what happens at expiry.
                </p>
              </div>
            <% end %>
          </section>
        </div>

        <div :if={@view == "custom"} class="flex flex-wrap items-start gap-5">
          <section
            aria-label="Contract"
            class="flex w-full min-w-0 flex-col gap-3 rounded-box border border-base-300 bg-base-200 px-5 py-4 sm:w-[420px] sm:flex-none"
          >
            <span class="text-[15px] font-semibold">
              <.t {copy("Type a contract")} />
            </span>
            <p class="text-[13px] text-muted">
              For a contract the scan and the stored chains don't have: copy its numbers from your
              broker and see the payoff.
            </p>
            <.position_form form={@form} params={@params} busy={@busy} quotes={@quotes} />
          </section>
          <section aria-label="Position" class="flex min-w-0 flex-[999_1_520px] flex-col gap-4">
            <.position
              :if={@analysis}
              analysis={@analysis}
              params={@params}
              form={@form}
              busy={@busy}
              tune={false}
            />
            <p
              :if={!@analysis}
              class="rounded-box border border-base-300 bg-base-200 px-5 py-4 text-[13px] text-muted"
            >
              Fill in the contract and press Analyze: what you pay, the payoff by price, and what happens at expiry.
            </p>
          </section>
        </div>

        <PaperBook.all_books
          :if={@view == "paper" and @paper == nil}
          books={@all_books}
          counts={@paper_counts}
        />

        <PaperBook.paper_book
          :if={@view == "paper" and @paper != nil}
          counts={@paper_counts}
          underlyings={@paper_underlyings}
          book={@paper}
          trade={@trade}
          leg={@leg}
          analysis={@paper_analysis}
          now={@spot_now}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :view, :string, required: true
  attr :current, :string, required: true
  attr :path, :string, required: true
  slot :inner_block, required: true

  defp view_tab(assigns) do
    ~H"""
    <.link
      patch={@path}
      aria-current={if @view == @current, do: "page"}
      class={[
        "-mb-px inline-flex min-h-10 items-center gap-2 border-b-2 px-3 text-[14px]",
        if(@view == @current,
          do: "border-primary font-medium text-base-content",
          else: "border-transparent text-muted hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp pane_class(pane, pane), do: "flex"
  defp pane_class(_pane, _name), do: "hidden sm:flex"

  defp scan_line(nil, _ideas, _chain), do: copy("no scan yet")

  defp scan_line(scanned_on, ideas, %{captured_at: nil}) do
    copy_n("%{day} scan · %{count} idea", "%{day} scan · %{count} ideas", length(ideas),
      day: Calendar.strftime(scanned_on, "%b %-d")
    )
  end

  defp scan_line(scanned_on, ideas, chain) do
    copy_n(
      "%{day} scan · %{count} idea · chains captured %{at}",
      "%{day} scan · %{count} ideas · chains captured %{at}",
      length(ideas),
      day: Calendar.strftime(scanned_on, "%b %-d"),
      at: "#{stamp(chain.captured_at)} #{zone_name(chain.captured_at)}"
    )
  end

  attr :ideas, :list, required: true
  attr :scanned_on, :any, default: nil
  attr :filter, :string, required: true
  attr :params, :map, required: true
  attr :class, :string, default: ""

  defp ideas_box(assigns) do
    live = Enum.filter(assigns.ideas, &(&1.status == "new"))
    dip_buy = Enum.count(live, &(&1.list == "dip_buy"))

    shown =
      case assigns.filter do
        "dip_buy" -> Enum.filter(live, &(&1.list == "dip_buy"))
        "calls" -> Enum.filter(live, &(&1.kind == "call"))
        "puts" -> Enum.filter(live, &(&1.kind == "put"))
        _ -> live
      end
      |> Enum.sort_by(&{&1.list != "dip_buy", &1.iv_rv || 99.0})

    assigns =
      assign(assigns,
        shown: shown,
        live: live,
        dip_buy: dip_buy,
        cheap_vol?: Enum.any?(assigns.ideas, &(&1.list == "cheap_vol"))
      )

    ~H"""
    <section class={[
      "flex-col overflow-hidden rounded-box border border-base-300 bg-base-200",
      @class
    ]}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 px-4 pt-3.5 pb-2.5">
        <span class="text-[15px] font-semibold"><.t {pcopy("heading", "Ideas")} /></span>
        <span :if={@scanned_on} class="text-[12px] text-muted">
          <.t {copy("implied vs realized, at the money · cheapest first")} />
        </span>
        <span :if={!@scanned_on} class="text-[12px] text-muted">no scan yet</span>
      </div>
      <div :if={@scanned_on} class="flex flex-wrap gap-1.5 px-4 pb-2.5">
        <button
          :for={
            {filter, label} <- [
              {"all", copy("All %{count}", count: length(@live))},
              {"dip_buy", copy("Dip-buy %{count}", count: @dip_buy)},
              {"calls", copy("Calls")},
              {"puts", copy("Puts")}
            ]
          }
          type="button"
          phx-click="filter"
          phx-value-filter={filter}
          aria-pressed={to_string(filter == @filter)}
          class={[
            "min-h-8 rounded-field border px-3 text-[13px]",
            if(filter == @filter,
              do: "border-primary font-medium text-primary",
              else: "border-base-300 text-muted hover:text-base-content"
            )
          ]}
        >
          <.t {label} />
        </button>
      </div>
      <p :if={!@scanned_on} class="border-t border-base-300 px-4 py-3 text-[13px] text-muted">
        The scan runs on trading days at 9:15 and 10:15 New York, after each chain snapshot. It lists calls worth a look when an index ETF closes
        oversold above its 100-day average, and each chain's at-the-money implied volatility against what the
        stock has actually been doing.
      </p>
      <p
        :if={@scanned_on && @shown == []}
        class="border-t border-base-300 px-4 py-3 text-[13px] text-muted"
      >
        {if @filter == "dip_buy",
          do:
            "No index ETF closed the last session with RSI(2) under 10 above its 100-day average (or that day's bar wasn't in yet), so no calls to suggest.",
          else: "Nothing left in this list."}
      </p>
      <p
        :if={@scanned_on && !@cheap_vol? && @filter != "dip_buy"}
        class="border-t border-base-300 px-4 py-3 text-[13px] text-muted"
      >
        Nothing is cheap today: on every chain the at-the-money options are priced for at least as
        much movement as the stock has actually had over the last 20 sessions. No options to buy on
        volatility today.
      </p>
      <div :if={@shown != []} class="max-h-[300px] overflow-y-auto border-t border-base-300">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="text-left text-[11px] text-muted">
              <th class="border-b border-base-300 px-4 py-2 font-medium">Contract</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Ask</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">
                <.t {copy("IV / RV")} />
              </th>
              <th class="border-b border-base-300 py-2 pr-2 pl-2 text-right font-medium">
                <.t {copy("Needs · gets")} />
              </th>
              <th class="border-b border-base-300 py-2 pr-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={idea <- @shown}
              id={"idea-#{idea.id}"}
              class={[
                "border-b border-neutral last:border-b-0",
                selected_idea?(idea, @params) &&
                  "bg-primary/10 shadow-[inset_3px_0_0_var(--color-primary)]"
              ]}
            >
              <td class="px-4 py-2">
                <button
                  type="button"
                  phx-click="idea"
                  phx-value-id={idea.id}
                  class="text-left hover:text-primary"
                >
                  <span class="font-medium">{idea.symbol} {money(idea.strike)} {idea.kind}</span>
                  <span class="block text-[12px] text-muted">
                    {Calendar.strftime(idea.expiration, "%b %-d")} · {idea.dte}d · Δ {num(idea.delta)}
                    <span
                      :if={idea.list == "dip_buy"}
                      class="ml-1 rounded-full bg-success/15 px-2 py-0.5 text-[11px] font-medium text-success"
                    >dip-buy</span>
                    <span
                      :if={idea.lottery}
                      class="ml-1 rounded-full bg-error px-2 py-0.5 text-[11px] font-semibold text-error-content"
                    ><.t {copy("Lottery")} /></span>
                  </span>
                  <span class="block text-[12px] text-muted">{idea.setup}</span>
                  <span :if={idea.chain_at} class="block text-[12px] text-muted">
                    Quotes from the {stamp(idea.chain_at, Opus.Clock.market_zone())} New York chain
                  </span>
                </button>
              </td>
              <td class="px-2 py-2 text-right">{num(idea.ask)}</td>
              <td class={["px-2 py-2 text-right", iv_rv_class(idea.iv_rv)]}>{num(idea.iv_rv)}</td>
              <td class="py-2 pr-2 pl-2 text-right whitespace-nowrap">
                {signed_pct(idea.breakeven_move_pct && idea.breakeven_move_pct * direction(idea.kind))} · ±{pct(
                  idea.expected_move_pct
                )}
              </td>
              <td class="py-2 pr-2 text-right">
                <button
                  type="button"
                  phx-click="dismiss"
                  phx-value-id={idea.id}
                  aria-label="Dismiss"
                  title="Dismiss"
                  class="px-1 text-muted hover:text-base-content"
                >×</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@scanned_on} class="border-t border-base-300 px-4 py-2.5 text-[12px] text-muted">
        <.t {copy("IV / RV under 1 means the market prices less movement than the stock has delivered; only those are listed. Dip-buy calls are limited to deltas of 0.30 to 0.70 with a spread within 10% of the mid.")} />
      </p>
    </section>
    """
  end

  defp selected_idea?(idea, params) do
    params["underlying"] == idea.symbol and params["strike"] == plain(idea.strike) and
      params["expiration"] == Date.to_iso8601(idea.expiration) and
      Options.kind(params["strategy"]) == idea.kind
  end

  attr :chain, :map, required: true
  attr :params, :map, required: true
  attr :class, :string, default: ""

  defp chain_box(%{chain: %{underlyings: []}} = assigns) do
    ~H"""
    <section class={[
      "flex-col gap-1 rounded-box border border-base-300 bg-base-200 px-4 py-3.5",
      @class
    ]}>
      <span class="text-[15px] font-semibold">Chain</span>
      <p class="text-[13px] text-muted">
        No stored option chains yet. Tick "Option chains" for a listing on the Instruments page and the next
        snapshot (9:00 or 10:00 New York) fills this in.
      </p>
    </section>
    """
  end

  defp chain_box(assigns) do
    ~H"""
    <section class={[
      "flex-col overflow-hidden rounded-box border border-base-300 bg-base-200",
      @class
    ]}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 px-4 pt-3.5 pb-2.5">
        <span class="text-[15px] font-semibold"><.t {pcopy("heading", "Chain")} />
        · {@chain.underlying} {@chain.kind}s</span>
        <span :if={@chain.captured_at} class="text-[12px] text-muted">
          spot {money(@chain.spot)} · {if @chain.expiration,
            do: Calendar.strftime(@chain.expiration, "%b %-d")}
        </span>
      </div>
      <form id="chain-form" phx-change="chain" class="flex flex-wrap gap-2.5 px-4 pb-2.5">
        <label class="flex flex-col gap-0.5 text-[12px] text-muted">
          Underlying
          <select name="chain[underlying]" class="select select-sm w-28">
            <option
              :for={u <- @chain.underlyings}
              value={u.symbol}
              selected={u.symbol == @chain.underlying}
            >
              {u.symbol}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-0.5 text-[12px] text-muted">
          Expiry
          <select name="chain[expiration]" class="select select-sm w-36">
            <option
              :for={e <- @chain.expiries}
              value={Date.to_iso8601(e)}
              selected={e == @chain.expiration}
            >
              {Calendar.strftime(e, "%b %-d")} · {Date.diff(e, Opus.Clock.today())}d
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-0.5 text-[12px] text-muted">
          Kind
          <select name="chain[kind]" class="select select-sm w-24">
            <option value="call" selected={@chain.kind == "call"}>Calls</option>
            <option value="put" selected={@chain.kind == "put"}>Puts</option>
          </select>
        </label>
      </form>
      <div :if={@chain.rows != []} class="max-h-[290px] overflow-y-auto border-t border-base-300">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="text-left text-[11px] text-muted">
              <th class="border-b border-base-300 px-4 py-2 font-medium">Strike</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Bid</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Ask</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">IV</th>
              <th class="border-b border-base-300 px-2 py-2 text-right font-medium">Δ</th>
              <th class="border-b border-base-300 py-2 pr-4 pl-2 text-right font-medium">OI</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @chain.rows}
              class={[
                "border-b border-neutral last:border-b-0",
                selected_strike?(row, @chain, @params) &&
                  "bg-primary/10 shadow-[inset_3px_0_0_var(--color-primary)]",
                row.at_the_money && !selected_strike?(row, @chain, @params) && "bg-base-300/40"
              ]}
            >
              <td class="px-4 py-1.5">
                <button
                  type="button"
                  phx-click="use"
                  phx-value-strike={plain(row.strike)}
                  class="font-medium hover:text-primary"
                >
                  {money(row.strike)}<span :if={row.at_the_money} class="ml-1 font-normal text-muted"><.t {copy("at the money")} /></span>
                </button>
              </td>
              <td class="px-2 py-1.5 text-right">{num(row.bid)}</td>
              <td class="px-2 py-1.5 text-right">{num(row.ask)}</td>
              <td class="px-2 py-1.5 text-right">
                {if row.volatility, do: "#{num(row.volatility, 1)}%", else: "—"}
              </td>
              <td class="px-2 py-1.5 text-right">{num(row.delta)}</td>
              <td class="py-1.5 pr-4 pl-2 text-right">{row.open_interest}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="border-t border-base-300 px-4 py-2.5 text-[12px] text-muted">
        <.t {copy("Click a strike and the position follows: the ask if you are buying, the bid if you are selling.")} />
      </p>
    </section>
    """
  end

  defp selected_strike?(row, chain, params) do
    (params["underlying"] == chain.underlying and params["strike"] == plain(row.strike) and
       chain.expiration) && params["expiration"] == Date.to_iso8601(chain.expiration)
  end

  attr :analysis, :map, required: true
  attr :params, :map, required: true
  attr :form, :map, required: true
  attr :busy, :boolean, required: true
  # The quick-edit fields repeat the full form's: off where that form is on
  # screen. They carry their own ids so the two can never collide.
  attr :tune, :boolean, default: true

  defp position(assigns) do
    ~H"""
    <div class="flex flex-col gap-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
        <div class="flex min-w-0 flex-col gap-0.5">
          <span class="text-[13px] text-muted">
            <.t {strategy_name(@analysis["strategy"])} />
          </span>
          <span class="text-[22px] font-semibold leading-tight tracking-tight">
            {@params["underlying"]} {money(@analysis["strike"])} {Options.kind(@params["strategy"])}, {expiry_label(
              @params["expiration"]
            )}
          </span>
          <span class="text-[13px] text-muted">
            {headline_text(@analysis)} Stock at {money(@analysis["spot"])}, {days(
              @analysis["years_to_expiry"]
            )} days to expiry{sigma_note(@analysis)}.
          </span>
        </div>
        <.form
          for={@form}
          id="position-tune"
          phx-change="change"
          phx-submit="analyze"
          class="flex flex-wrap items-end gap-2.5"
        >
          <.input
            :if={@tune}
            field={@form[:contracts]}
            id="tune_contracts"
            type="text"
            inputmode="numeric"
            label="Contracts"
            class="input input-sm w-20"
          />
          <.input
            :if={@tune}
            field={@form[:premium]}
            id="tune_premium"
            type="text"
            inputmode="decimal"
            label="Premium"
            class="input input-sm w-24"
          />
          <.input
            :if={@tune}
            field={@form[:sigma]}
            id="tune_sigma"
            type="text"
            inputmode="decimal"
            label="Vol %"
            class="input input-sm w-24"
          />
          <.input
            :if={@tune and @params["strategy"] == "covered_call"}
            field={@form[:cost_basis]}
            id="tune_cost_basis"
            type="text"
            inputmode="decimal"
            label="Shares cost"
            class="input input-sm w-24"
          />
          <button :if={@tune} type="submit" disabled={@busy} class="btn btn-sm mb-2">
            <span :if={@busy}>…</span>
            <.t :if={!@busy} {copy("Update")} />
          </button>
          <button
            type="button"
            phx-click="side"
            class="btn btn-sm btn-ghost mb-2 min-w-36 whitespace-nowrap"
          >
            <.t :if={Options.side(@params["strategy"]) == :buy} {copy("Sell it instead")} />
            <.t :if={Options.side(@params["strategy"]) != :buy} {copy("Buy it instead")} />
          </button>
        </.form>
      </div>

      <.payoff_chart analysis={@analysis} class="hidden sm:block" />
      <.payoff_chart analysis={@analysis} compact class="sm:hidden" />
    </div>

    <div class="grid grid-cols-2 gap-x-5 gap-y-3.5 rounded-box border border-base-300 bg-base-200 px-5 py-4 sm:grid-cols-3 lg:grid-cols-6">
      <.stat
        :for={stat <- stats(@analysis)}
        label={stat.label}
        value={stat.value}
        hint={stat.hint}
        tone={stat.tone}
      />
    </div>

    <.outcomes analysis={@analysis} />

    <details class="rounded-box border border-base-300 bg-base-200">
      <summary class="flex cursor-pointer items-center justify-between px-5 py-3 text-[14px] font-medium">
        <.t {copy("Price by price, at expiry")} />
        <span class="text-[12px] font-normal text-muted">{length(@analysis["scenarios"])} rows</span>
      </summary>
      <div class="px-5 pb-4"><.scenario_table analysis={@analysis} /></div>
    </details>
    """
  end

  defp expiry_label(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d")
      _ -> iso
    end
  end

  defp expiry_label(_), do: ""

  attr :form, :map, required: true
  attr :params, :map, required: true
  attr :busy, :boolean, required: true
  attr :quotes, :map, required: true

  defp position_form(assigns) do
    assigns = assign(assigns, picked: picked_quote(assigns.quotes.rows, assigns.params))

    ~H"""
    <.form for={@form} id="position-form" phx-change="change" phx-submit="analyze">
      <div class="grid grid-cols-2 gap-x-4 gap-y-1 [&>*]:min-w-0">
        <div class="col-span-2">
          <.input
            field={@form[:strategy]}
            type="select"
            label="Strategy"
            options={Options.strategy_options()}
          />
        </div>
        <.input
          field={@form[:underlying]}
          label="Underlying"
          placeholder="SPY"
          phx-debounce="400"
        />
        <%= if @quotes.rows != [] do %>
          <.input
            field={@form[:expiration]}
            type="select"
            label="Expiration"
            options={for e <- @quotes.expiries, do: {expiry_option(e), Date.to_iso8601(e)}}
          />
          <.input
            field={@form[:strike]}
            type="select"
            label="Strike"
            options={for r <- @quotes.rows, do: {strike_option(r), plain(r.strike)}}
          />
        <% else %>
          <.input field={@form[:expiration]} type="date" label="Expiration" />
          <.input
            field={@form[:strike]}
            type="text"
            inputmode="decimal"
            label="Strike"
            placeholder="640"
          />
        <% end %>
        <.input
          field={@form[:premium]}
          type="text"
          inputmode="decimal"
          label="Premium per share"
          placeholder="6.40"
        />
        <.input field={@form[:contracts]} type="text" inputmode="numeric" label="Contracts" />
        <.input
          field={@form[:spot]}
          type="text"
          inputmode="decimal"
          label="Stock price"
          placeholder="last close"
        />
        <.input
          field={@form[:sigma]}
          type="text"
          inputmode="decimal"
          label="Volatility %"
          placeholder="from the premium"
        />
        <.input
          :if={@params["strategy"] == "covered_call"}
          field={@form[:cost_basis]}
          type="text"
          inputmode="decimal"
          label="Your shares cost"
          placeholder="stock price"
        />
      </div>
      <p :if={quote = picked_quote(@quotes.rows, @params)} class="mt-1 text-[12px] text-muted">
        From the {stamp(quote.captured_at)} {zone_name(quote.captured_at)} snapshot: bid {money(
          quote.bid
        )}, ask {money(quote.ask)}.
        The premium is the {if Options.side(@params["strategy"]) == :sell,
          do: "bid (what selling gets you)",
          else: "ask (what buying costs you)"}; type over it to try another price.
      </p>
      <p class="mt-1 text-[12px] text-muted">
        Strike and premium are per share; one contract is 100 shares. Leave stock price or
        volatility blank to use the last close or the volatility the premium implies.
      </p>
      <.button variant="primary" disabled={@busy} class="btn btn-primary mt-4 w-full">
        {if @busy, do: "Working…", else: "Show me what happens"}
      </.button>
    </.form>
    """
  end

  attr :analysis, :map, required: true

  defp outcomes(assigns) do
    ~H"""
    <section class="grid gap-3.5 sm:grid-cols-2">
      <.outcome_card
        :for={card <- outcome_cards(@analysis)}
        title={card.title}
        body={card.body}
        amount={card.amount}
        tone={card.tone}
      />
    </section>
    """
  end

  attr :title, :map, required: true, doc: "copy/1"
  attr :body, :string, required: true
  attr :amount, :map, required: true, doc: "copy/1"
  attr :tone, :atom, required: true

  defp outcome_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <span class="text-[14px] font-semibold"><.t {@title} /></span>
      <p class="text-[13px] leading-relaxed text-muted">{@body}</p>
      <span class={["text-[18px] font-semibold", tone_class(@tone)]}><.t {@amount} /></span>
    </div>
    """
  end

  attr :label, :map, required: true, doc: "copy/1"
  attr :value, :string, required: true
  attr :hint, :string, required: true
  attr :tone, :atom, default: :neutral

  defp stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs text-muted"><.t {@label} /></span>
      <span class={["text-[19px] font-semibold", tone_class(@tone)]}>{@value}</span>
      <span class="text-xs leading-snug text-muted">{@hint}</span>
    </div>
    """
  end

  attr :analysis, :map, required: true

  defp scenario_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full min-w-[520px] border-collapse text-sm">
        <thead>
          <tr class="text-left text-xs text-muted">
            <th class="border-b border-base-300 py-2.5 font-medium">Stock at expiry</th>
            <th class="border-b border-base-300 py-2.5 text-right font-medium">Change</th>
            <th class="border-b border-base-300 py-2.5 font-medium">What happens</th>
            <th class="border-b border-base-300 py-2.5 text-right font-medium">Your result</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @analysis["scenarios"]} class={row_class(row, @analysis)}>
            <td class="py-2.5 font-medium">{money(row["price"])}{marker(row, @analysis)}</td>
            <td class="py-2.5 text-right">{signed_pct(row["change"])}</td>
            <td class="py-2.5">{outcome_text(row["outcome"])}</td>
            <td class={["py-2.5 text-right font-medium", tone_class(pnl_tone(row["pnl"]))]}>
              {signed_money(row["pnl"])}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp direction("put"), do: -1
  defp direction(_), do: 1

  defp iv_rv_class(ratio) when is_number(ratio) and ratio < 1.0, do: "text-success"
  defp iv_rv_class(ratio) when is_number(ratio) and ratio > 1.3, do: "text-warning"
  defp iv_rv_class(_), do: ""

  # --- copy ---

  defp strategy_name("cash_secured_put"), do: copy("Cash-secured put")
  defp strategy_name("covered_call"), do: copy("Covered call")
  defp strategy_name("long_call"), do: copy("Long call")
  defp strategy_name("long_put"), do: copy("Long put")
  defp strategy_name(other), do: %{s: other, wsb: other}

  defp headline_text(%{"strategy" => "cash_secured_put"} = a) do
    "You collect #{money(a["premium_total"])} now and promise to buy #{shares(a["shares"])} shares at #{money(a["strike"])} if asked."
  end

  defp headline_text(%{"strategy" => "covered_call"} = a) do
    "You collect #{money(a["premium_total"])} now and promise to sell your #{shares(a["shares"])} shares at #{money(a["strike"])} if asked."
  end

  defp headline_text(%{"strategy" => "long_call"} = a) do
    "You pay #{money(a["premium_total"])} for the right to buy #{shares(a["shares"])} shares at #{money(a["strike"])}."
  end

  defp headline_text(%{"strategy" => "long_put"} = a) do
    "You pay #{money(a["premium_total"])} for the right to sell #{shares(a["shares"])} shares at #{money(a["strike"])}."
  end

  defp outcome_cards(%{"strategy" => "cash_secured_put"} = a) do
    [
      %{
        title: copy("If the stock stays above %{strike}", strike: money(a["strike"])),
        body:
          "The put expires worthless. Nobody makes you buy anything. You keep the premium and your #{money(a["capital_required"])} is free again.",
        amount: copy("+%{premium} kept", premium: money(a["premium_total"])),
        tone: :good
      },
      %{
        title: copy("If the stock closes below %{strike}", strike: money(a["strike"])),
        body:
          "You are assigned: you buy #{shares(a["shares"])} shares at #{money(a["strike"])}, paying #{money(a["capital_required"])}. With the premium, your real cost is #{money(a["breakeven"])} a share. You lose money only if the stock is below that.",
        amount: copy("Own shares at %{breakeven} effective", breakeven: money(a["breakeven"])),
        tone: :neutral
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "covered_call"} = a) do
    [
      %{
        title: copy("If the stock stays below %{strike}", strike: money(a["strike"])),
        body:
          "The call expires worthless. You keep your shares and the premium, and can sell another call next cycle.",
        amount: copy("+%{premium} kept", premium: money(a["premium_total"])),
        tone: :good
      },
      %{
        title: copy("If the stock closes above %{strike}", strike: money(a["strike"])),
        body:
          "You are assigned: your #{shares(a["shares"])} shares are sold at #{money(a["strike"])} no matter how high the stock went. You keep the premium too. That is the most this position can make.",
        amount: copy("%{gain} best case", gain: payoff_money(a["max_gain"])),
        tone: :good
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "long_call"} = a) do
    [
      %{
        title: pcopy("buyer", "If the stock stays below %{strike}", strike: money(a["strike"])),
        body:
          "The call expires worthless and the premium is gone. That is the most you can lose.",
        amount: copy("-%{loss} lost", loss: money(a["max_loss"])),
        tone: :bad
      },
      %{
        title: copy("If the stock closes above %{breakeven}", breakeven: money(a["breakeven"])),
        body:
          "You make money. Between #{money(a["strike"])} and #{money(a["breakeven"])} the call has value but less than you paid. Above #{money(a["breakeven"])} every dollar of stock is #{money(a["shares"])} to you.",
        amount: copy("Unlimited upside"),
        tone: :good
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "long_put"} = a) do
    [
      %{
        title: pcopy("buyer", "If the stock stays above %{strike}", strike: money(a["strike"])),
        body: "The put expires worthless and the premium is gone. That is the most you can lose.",
        amount: copy("-%{loss} lost", loss: money(a["max_loss"])),
        tone: :bad
      },
      %{
        title: copy("If the stock closes below %{breakeven}", breakeven: money(a["breakeven"])),
        body:
          "You make money. The put is worth the distance from #{money(a["strike"])} down to the stock price, less what you paid. Best case the stock goes to zero.",
        amount: pcopy("buyer", "%{gain} best case", gain: payoff_money(a["max_gain"])),
        tone: :good
      }
    ]
  end

  defp stats(a) do
    seller? = a["strategy"] in ["cash_secured_put", "covered_call"]

    [
      %{
        label: if(seller?, do: copy("Money set aside"), else: copy("Money at risk")),
        value: money(a["capital_required"]),
        tone: if(seller?, do: :warn, else: :bad),
        hint:
          if(seller?,
            do: "Cash (or shares) you must hold so you can honour the contract.",
            else: "The premium. A bought option can go to zero, never below."
          )
      },
      %{
        label: copy("Premium"),
        value:
          if(seller?, do: "+#{money(a["premium_total"])}", else: "-#{money(a["premium_total"])}"),
        tone: if(seller?, do: :good, else: :bad),
        hint: if(seller?, do: "Paid to you today, yours to keep.", else: "Paid by you today.")
      },
      # A yield only means something when money is set aside to earn the
      # premium; on a bought option it would be the premium over itself.
      if(seller?,
        do: %{
          label: copy("Yield"),
          value: "#{pct(a["yield_on_capital"])} · #{pct(a["annualized_yield"])}/yr",
          tone: :good,
          hint: "Premium over money set aside, then scaled to a year for comparing expiries."
        }
      ),
      %{
        label: copy("Breakeven"),
        value: money(a["breakeven"]),
        tone: :warn,
        hint: "Stock price at expiry where you neither make nor lose money."
      },
      %{
        label: if(seller?, do: copy("Chance of assignment"), else: copy("Chance it pays")),
        value: maybe_pct(a["probability_itm"]),
        tone: :warn,
        hint: "Model estimate from the option's own volatility. Not a promise."
      },
      %{
        label: copy("Chance of a profit"),
        value: maybe_pct(a["probability_profit"]),
        tone: odds_tone(a["probability_profit"]),
        hint: "Chance the stock ends on the right side of breakeven."
      },
      %{
        label: copy("Expected move"),
        value: if(a["expected_move"], do: "±#{money(a["expected_move"])}", else: "—"),
        tone: :warn,
        hint: "A typical one-standard-deviation move by expiry, from the volatility."
      },
      %{
        label: copy("Worst case"),
        value: "-#{money(a["max_loss"])}",
        tone: :bad,
        hint: worst_case_hint(a["strategy"])
      }
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp worst_case_hint("cash_secured_put"),
    do:
      "If the stock goes to zero: you buy the shares at the strike and they are worth nothing, less the premium you kept."

  defp worst_case_hint("covered_call"),
    do:
      "If the stock goes to zero: the shares you hold are worth nothing, less the premium you kept."

  defp worst_case_hint("long_call"),
    do:
      "The premium you paid, if the stock ends at or below the strike and the call expires worthless."

  defp worst_case_hint("long_put"),
    do:
      "The premium you paid, if the stock ends at or above the strike and the put expires worthless."

  defp worst_case_hint(_strategy), do: "The most this position can lose by expiry."

  defp outcome_text("assigned"), do: "Assigned: shares change hands at the strike"
  defp outcome_text("expires_worthless"), do: "Expires worthless: you keep the premium"
  defp outcome_text("in_the_money"), do: "In the money: the option has value"
  defp outcome_text("expired"), do: "Expires worthless: premium lost"
  defp outcome_text(other), do: other

  defp marker(row, a) do
    cond do
      near?(row["price"], a["strike"]) -> " (strike)"
      near?(row["price"], a["breakeven"]) -> " (breakeven)"
      near?(row["price"], a["spot"]) -> " (today)"
      true -> ""
    end
  end

  defp row_class(row, a) do
    if near?(row["price"], a["strike"]) or near?(row["price"], a["breakeven"]),
      do: "bg-base-300/40",
      else: ""
  end

  defp near?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-6
  defp near?(_, _), do: false

  defp sigma_note(%{"sigma" => nil}), do: ", volatility could not be inferred from that premium"

  defp sigma_note(%{"sigma" => sigma, "sigma_implied" => implied}) do
    ", volatility #{pct(sigma)}#{if implied, do: " implied by the premium", else: ""}"
  end

  defp days(years) when is_number(years), do: round(years * 365)
  defp days(_), do: 0

  defp maybe_pct(nil), do: "—"
  defp maybe_pct(value), do: pct(value)

  # A payoff with no cap has no number.
  defp payoff_money(nil), do: "unlimited"
  defp payoff_money(value), do: signed_money(value)

  defp pnl_tone(value) when is_number(value) and value > 0, do: :good
  defp pnl_tone(value) when is_number(value) and value < 0, do: :bad
  defp pnl_tone(_), do: :neutral

  defp tone_class(:good), do: "text-success"
  defp tone_class(:bad), do: "text-error"
  defp tone_class(:warn), do: "text-warning"
  defp tone_class(:neutral), do: ""

  defp odds_tone(p) when is_number(p) and p >= 0.5, do: :good
  defp odds_tone(p) when is_number(p), do: :bad
  defp odds_tone(_), do: :neutral

  defp open_words(1), do: "1 trade open"
  defp open_words(n), do: "#{n} trades open"
end
