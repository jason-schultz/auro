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

  alias Opus.Options

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
    {:ok,
     assign(socket,
       page_title: "Options",
       form: to_form(@defaults, as: :position),
       params: @defaults,
       analysis: nil,
       error: nil,
       busy: false
     )}
  end

  @impl true
  def handle_event("change", %{"position" => params}, socket) do
    params = Map.merge(socket.assigns.params, params)
    {:noreply, assign(socket, params: params, form: to_form(params, as: :position))}
  end

  def handle_event("analyze", %{"position" => params}, socket) do
    params = Map.merge(socket.assigns.params, params)
    socket = assign(socket, params: params, form: to_form(params, as: :position), busy: true)

    case Options.scenarios(params) do
      {:ok, analysis} -> {:noreply, assign(socket, analysis: analysis, error: nil, busy: false)}
      {:error, reason} -> {:noreply, assign(socket, error: describe(reason), busy: false)}
    end
  end

  defp describe(message) when is_binary(message), do: message
  defp describe({:http_error, _status, %{"error" => message}}), do: message
  defp describe({:http_error, status, _body}), do: "Auro answered with status #{status}."
  defp describe(%{reason: :econnrefused}), do: "Auro is not running."
  defp describe(_), do: "Could not reach Auro."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-10">
        <header class="flex flex-col gap-1">
          <h1 class="text-[22px] font-semibold tracking-tight">Options</h1>
          <p class="text-[13px] text-muted">
            Describe one position and see what happens at expiry. Nothing here places a trade.
          </p>
        </header>

        <.position_form form={@form} params={@params} busy={@busy} />

        <p
          :if={@error}
          role="alert"
          class="rounded-box border border-error/40 bg-base-200 px-4 py-3 text-sm"
        >
          {@error}
        </p>

        <%= if @analysis do %>
          <.headline analysis={@analysis} />
          <.outcomes analysis={@analysis} />
          <.numbers analysis={@analysis} />
          <.scenario_table analysis={@analysis} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :params, :map, required: true
  attr :busy, :boolean, required: true

  defp position_form(assigns) do
    ~H"""
    <.form for={@form} id="position-form" phx-change="change" phx-submit="analyze">
      <div class="grid grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-4">
        <.input field={@form[:underlying]} label="Underlying" placeholder="SPY" />
        <.input
          field={@form[:strategy]}
          type="select"
          label="Strategy"
          options={Options.strategy_options()}
        />
        <.input
          field={@form[:strike]}
          type="text"
          inputmode="decimal"
          label="Strike"
          placeholder="640"
        />
        <.input field={@form[:expiration]} type="date" label="Expiration" />
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
          label="Stock price (blank = last close)"
        />
        <.input
          field={@form[:sigma]}
          type="text"
          inputmode="decimal"
          label="Volatility % (blank = from premium)"
        />
        <.input
          :if={@params["strategy"] == "covered_call"}
          field={@form[:cost_basis]}
          type="text"
          inputmode="decimal"
          label="What your shares cost (blank = stock price)"
        />
      </div>
      <div class="mt-4 flex items-center gap-4">
        <.button variant="primary" disabled={@busy}>
          {if @busy, do: "Working…", else: "Show me what happens"}
        </.button>
        <span class="text-[13px] text-muted">Premium and strike are per share; a contract is 100 shares.</span>
      </div>
    </.form>
    """
  end

  attr :analysis, :map, required: true

  defp headline(assigns) do
    ~H"""
    <section class="flex flex-col gap-1">
      <span class="text-[13px] text-muted">{strategy_name(@analysis["strategy"])}</span>
      <span class="text-2xl font-semibold leading-tight tracking-tight">
        {headline_text(@analysis)}
      </span>
      <span class="text-[13px] text-muted">
        Stock at {money(@analysis["spot"])}, strike {money(@analysis["strike"])}, {days(
          @analysis["years_to_expiry"]
        )} days to expiry{sigma_note(@analysis)}.
      </span>
    </section>
    """
  end

  attr :analysis, :map, required: true

  defp outcomes(assigns) do
    ~H"""
    <section class="grid gap-4 sm:grid-cols-2">
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

  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :amount, :any, required: true
  attr :tone, :atom, required: true

  defp outcome_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 rounded-box border border-base-300 bg-base-200 px-5 py-4">
      <span class="text-[15px] font-semibold">{@title}</span>
      <p class="text-sm leading-relaxed">{@body}</p>
      <span class={["text-xl font-semibold", tone_class(@tone)]}>{@amount}</span>
    </div>
    """
  end

  attr :analysis, :map, required: true

  defp numbers(assigns) do
    ~H"""
    <section class="grid grid-cols-2 gap-x-6 gap-y-5 sm:grid-cols-3 lg:grid-cols-4">
      <.stat :for={stat <- stats(@analysis)} label={stat.label} value={stat.value} hint={stat.hint} />
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs text-muted">{@label}</span>
      <span class="text-lg font-semibold">{@value}</span>
      <span class="text-xs leading-snug text-muted">{@hint}</span>
    </div>
    """
  end

  attr :analysis, :map, required: true

  defp scenario_table(assigns) do
    ~H"""
    <section class="flex flex-col gap-3">
      <span class="text-[15px] font-semibold">Price by price, at expiry</span>
      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-200 px-4 py-1.5">
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
    </section>
    """
  end

  # --- copy ---

  defp strategy_name("cash_secured_put"), do: "Cash-secured put"
  defp strategy_name("covered_call"), do: "Covered call"
  defp strategy_name("long_call"), do: "Long call"
  defp strategy_name("long_put"), do: "Long put"
  defp strategy_name(other), do: other

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
        title: "If the stock stays above #{money(a["strike"])}",
        body:
          "The put expires worthless. Nobody makes you buy anything. You keep the premium and your #{money(a["capital_required"])} is free again.",
        amount: "+#{money(a["premium_total"])} kept",
        tone: :good
      },
      %{
        title: "If the stock closes below #{money(a["strike"])}",
        body:
          "You are assigned: you buy #{shares(a["shares"])} shares at #{money(a["strike"])}, paying #{money(a["capital_required"])}. With the premium, your real cost is #{money(a["breakeven"])} a share. You lose money only if the stock is below that.",
        amount: "Own shares at #{money(a["breakeven"])} effective",
        tone: :neutral
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "covered_call"} = a) do
    [
      %{
        title: "If the stock stays below #{money(a["strike"])}",
        body:
          "The call expires worthless. You keep your shares and the premium, and can sell another call next cycle.",
        amount: "+#{money(a["premium_total"])} kept",
        tone: :good
      },
      %{
        title: "If the stock closes above #{money(a["strike"])}",
        body:
          "You are assigned: your #{shares(a["shares"])} shares are sold at #{money(a["strike"])} no matter how high the stock went. You keep the premium too. That is the most this position can make.",
        amount: "#{signed_money(a["max_gain"])} best case",
        tone: :good
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "long_call"} = a) do
    [
      %{
        title: "If the stock stays below #{money(a["strike"])}",
        body:
          "The call expires worthless and the premium is gone. That is the most you can lose.",
        amount: "-#{money(a["max_loss"])} lost",
        tone: :bad
      },
      %{
        title: "If the stock closes above #{money(a["breakeven"])}",
        body:
          "You make money. Between #{money(a["strike"])} and #{money(a["breakeven"])} the call has value but less than you paid. Above #{money(a["breakeven"])} every dollar of stock is #{money(a["shares"])} to you.",
        amount: "Unlimited upside",
        tone: :good
      }
    ]
  end

  defp outcome_cards(%{"strategy" => "long_put"} = a) do
    [
      %{
        title: "If the stock stays above #{money(a["strike"])}",
        body: "The put expires worthless and the premium is gone. That is the most you can lose.",
        amount: "-#{money(a["max_loss"])} lost",
        tone: :bad
      },
      %{
        title: "If the stock closes below #{money(a["breakeven"])}",
        body:
          "You make money. The put is worth the distance from #{money(a["strike"])} down to the stock price, less what you paid. Best case the stock goes to zero.",
        amount: "#{signed_money(a["max_gain"])} best case",
        tone: :good
      }
    ]
  end

  defp stats(a) do
    seller? = a["strategy"] in ["cash_secured_put", "covered_call"]

    [
      %{
        label: if(seller?, do: "Money set aside", else: "Money at risk"),
        value: money(a["capital_required"]),
        hint:
          if(seller?,
            do: "Cash (or shares) you must hold so you can honour the contract.",
            else: "The premium. A bought option can go to zero, never below."
          )
      },
      %{
        label: "Premium",
        value:
          if(seller?, do: "+#{money(a["premium_total"])}", else: "-#{money(a["premium_total"])}"),
        hint: if(seller?, do: "Paid to you today, yours to keep.", else: "Paid by you today.")
      },
      %{
        label: "Yield",
        value: "#{pct(a["yield_on_capital"])} · #{pct(a["annualized_yield"])}/yr",
        hint: "Premium over money set aside, then scaled to a year for comparing expiries."
      },
      %{
        label: "Breakeven",
        value: money(a["breakeven"]),
        hint: "Stock price at expiry where you neither make nor lose money."
      },
      %{
        label: if(seller?, do: "Chance of assignment", else: "Chance it pays"),
        value: maybe_pct(a["probability_itm"]),
        hint: "Model estimate from the option's own volatility. Not a promise."
      },
      %{
        label: "Chance of a profit",
        value: maybe_pct(a["probability_profit"]),
        hint: "Chance the stock ends on the right side of breakeven."
      },
      %{
        label: "Expected move",
        value: if(a["expected_move"], do: "±#{money(a["expected_move"])}", else: "—"),
        hint: "A typical one-standard-deviation move by expiry, from the volatility."
      },
      %{
        label: "Worst case",
        value: "-#{money(a["max_loss"])}",
        hint: "If the stock goes to zero (or, for a long call, the premium)."
      }
    ]
  end

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

  defp signed_pct(value) when is_number(value) and value > 0, do: "+#{pct(value)}"
  defp signed_pct(value), do: pct(value)

  defp signed_money(nil), do: "unlimited"
  defp signed_money(value) when is_number(value) and value > 0, do: "+#{money(value)}"
  defp signed_money(value) when is_number(value) and value < 0, do: "-#{money(abs(value))}"
  defp signed_money(value), do: money(value)

  defp pnl_tone(value) when is_number(value) and value > 0, do: :good
  defp pnl_tone(value) when is_number(value) and value < 0, do: :bad
  defp pnl_tone(_), do: :neutral

  defp tone_class(:good), do: "text-success"
  defp tone_class(:bad), do: "text-error"
  defp tone_class(:neutral), do: ""
end
