defmodule Opus.Trading.ShareAlerts do
  @moduledoc """
  Share alerts: strategies assigned to a stock or ETF tell you what to do
  at Wealthsimple, and you place the order by hand. Nothing here, or in the
  engine, contacts Wealthsimple or places an order.

  A market tested as shares held goes live this way (`action_for/1`), with
  a dollar amount per buy. At 15:45 New York on trading days
  (`Opus.Trading.ShareAlertWorker`) the live engine decides each switched-on
  assignment on its daily bars plus the day so far, by the same rules the
  backtest ran (`POST /api/share-alerts/evaluate`); a buy or sell becomes an
  alert here, on Discord and on the Dashboard, where it stays until you log
  it with Log trade (`log_fill/2`) or say you didn't trade (`skip/1`).

  Logged fills are the only record of what an assignment holds: the next
  check knows you hold shares only because you logged the buy. An alert not
  logged by the next check counts as not traded (`skip_unlogged/1`). A
  logged fill also changes the account's holdings and cash on the Accounts
  page (`Opus.Accounts.apply_fill/2`).
  """

  import Ecto.Query

  require Logger

  alias Opus.Accounts
  alias Opus.Auro.Client
  alias Opus.Clock
  alias Opus.Dashboard.{Discord, Feed}
  alias Opus.Instruments
  alias Opus.Repo
  alias Opus.Trading.ShareAlert

  @default_amount 500.0
  # The limit price suggested around the 15:45 price, so the order fills
  # in the last minutes without chasing.
  @limit_buffer 0.002

  @type assignment :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          symbol: String.t(),
          currency: String.t(),
          amount: float()
        }

  @doc """
  The action an assignment on `instrument` gets when it goes live: share
  alerts with the default amount for a market tested as shares held, nil
  (OANDA trades) for anything else.
  """
  @spec action_for(String.t()) :: map() | nil
  def action_for(instrument) do
    if Instruments.share_market?(instrument),
      do: %{type: "share_alert", amount: @default_amount}
  end

  @doc """
  Change the dollar amount each buy alert of share-alert assignment `id`
  is for. `{:error, words}` when it isn't a number above 0.
  """
  @spec set_amount(Ecto.UUID.t(), String.t()) :: {:ok, float()} | {:error, String.t()}
  def set_amount(id, text) do
    with {:ok, amount} <- positive(text, "The amount"),
         {1, _} <-
           from(ls in "live_strategies",
             where:
               ls.id == type(^id, Ecto.UUID) and
                 fragment("?->>'type' = 'share_alert'", ls.action)
           )
           |> Repo.update_all(
             set: [
               action: %{"type" => "share_alert", "amount" => amount},
               updated_at: DateTime.utc_now()
             ]
           ) do
      {:ok, amount}
    else
      {0, _} -> {:error, "That strategy doesn't send share alerts."}
      error -> error
    end
  end

  @doc "The switched-on share-alert assignments."
  @spec assignments() :: [assignment()]
  def assignments do
    from(ls in "live_strategies",
      join: s in "strategies",
      on: s.id == ls.strategy_id,
      left_join: i in "instruments",
      on: i.id == ls.instrument_id,
      where: ls.enabled and fragment("?->>'type' = 'share_alert'", ls.action),
      order_by: s.name,
      select: %{
        id: type(ls.id, Ecto.UUID),
        name: s.name,
        symbol: coalesce(i.questrade_symbol, ls.instrument),
        currency: coalesce(i.currency, "USD"),
        amount: fragment("(?->>'amount')::float", ls.action)
      }
    )
    |> Repo.all()
  end

  @doc """
  What each of `ids` holds from its logged fills: the last fill a buy means
  it holds, with the day bought (the alert's day, the bar the strategy
  decided on), the stop set then, the shares and the account.
  """
  @spec held([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def held(ids) do
    from(a in ShareAlert,
      where: a.live_strategy_id in ^ids and a.status == "filled",
      distinct: a.live_strategy_id,
      order_by: [asc: a.live_strategy_id, desc: a.day, desc: a.id]
    )
    |> Repo.all()
    |> Enum.filter(&(&1.side == "buy"))
    |> Map.new(
      &{&1.live_strategy_id,
       %{
         entry_day: &1.day,
         stop_price: &1.stop_price,
         shares: &1.filled_shares,
         account: &1.account
       }}
    )
  end

  @doc """
  The 15:45 check: earlier alerts not logged count as not traded, then
  each switched-on assignment is decided and its buys and sells become
  alerts, sent to Discord. `:ok` with nothing switched on.
  """
  @spec run(Date.t()) :: :ok | {:error, term()}
  def run(day \\ Clock.today()) do
    skip_unlogged(day)

    case assignments() do
      [] ->
        :ok

      assignments ->
        held = held(Enum.map(assignments, & &1.id))

        requests =
          Enum.map(assignments, fn a ->
            %{id: a.id, held: held[a.id] && Map.take(held[a.id], [:entry_day, :stop_price])}
          end)

        with {:ok, decisions} <- Client.evaluate_share_alerts(requests) do
          {alerts, unready} = record(decisions, assignments, held, day)
          send_alerts(alerts, unready)
          Feed.changed()
          :ok
        end
    end
  end

  @doc """
  Store the buys and sells among the engine's `decisions` as the day's
  alerts (one per assignment a day; a second check the same day keeps the
  first). Returns the alerts stored, each with its assignment, and the
  assignments that couldn't be decided, with why.
  """
  @spec record([map()], [assignment()], map(), Date.t()) ::
          {[{ShareAlert.t(), assignment()}], [{assignment(), String.t()}]}
  def record(decisions, assignments, held, day) do
    by_id = Map.new(assignments, &{&1.id, &1})

    Enum.reduce(decisions, {[], []}, fn decision, {alerts, unready} ->
      case {by_id[decision["id"]], decision["action"]} do
        {nil, _action} ->
          {alerts, unready}

        {assignment, side} when side in ~w(buy sell) ->
          alert = alert(decision, assignment, held[assignment.id], day)

          case Repo.insert(alert,
                 on_conflict: :nothing,
                 conflict_target: [:live_strategy_id, :day]
               ) do
            {:ok, %ShareAlert{id: id} = stored} when not is_nil(id) ->
              {[{stored, assignment} | alerts], unready}

            _already_alerted_today ->
              {alerts, unready}
          end

        {assignment, "unready"} ->
          {alerts, [{assignment, decision["why"]} | unready]}

        _hold_or_wait ->
          {alerts, unready}
      end
    end)
    |> then(fn {alerts, unready} -> {Enum.reverse(alerts), Enum.reverse(unready)} end)
  end

  defp alert(%{"action" => "buy"} = d, assignment, _held, day) do
    %ShareAlert{
      live_strategy_id: assignment.id,
      day: day,
      side: "buy",
      symbol: assignment.symbol,
      currency: assignment.currency,
      price: d["price"],
      stop_price: d["stop_price"],
      shares: buy_shares(assignment.amount, d["price"])
    }
  end

  defp alert(%{"action" => "sell"} = d, assignment, held, day) do
    %ShareAlert{
      live_strategy_id: assignment.id,
      day: day,
      side: "sell",
      reason: d["reason"],
      symbol: assignment.symbol,
      currency: assignment.currency,
      price: d["price"],
      stop_price: held && held.stop_price,
      shares: held && held.shares
    }
  end

  @doc """
  Whole shares the amount buys at `price`, or a fraction (to 4 places)
  when it buys less than one: Wealthsimple sells fractions of most US and
  Canadian listings.
  """
  @spec buy_shares(number() | nil, number()) :: float()
  def buy_shares(amount, price) when is_number(amount) and amount > 0 and price > 0 do
    case Float.floor(amount / price) do
      whole when whole >= 1 -> whole
      _less -> Float.round(amount / price, 4)
    end
  end

  def buy_shares(_amount, _price), do: 0.0

  @doc "The suggested limit price: a little past the alert's price, in the order's favour to fill."
  @spec limit_price(ShareAlert.t()) :: float()
  def limit_price(%ShareAlert{side: "buy", price: p}), do: Float.round(p * (1 + @limit_buffer), 2)

  def limit_price(%ShareAlert{side: "sell", price: p}),
    do: Float.round(p * (1 - @limit_buffer), 2)

  @doc "Alerts before `day` still waiting for a log count as not traded."
  @spec skip_unlogged(Date.t()) :: non_neg_integer()
  def skip_unlogged(day) do
    {count, _} =
      from(a in ShareAlert, where: a.status == "open" and a.day < ^day)
      |> Repo.update_all(set: [status: "skipped", updated_at: DateTime.utc_now(:second)])

    count
  end

  @doc "The alerts waiting for your log, oldest first, each with its strategy's name."
  @spec open() :: [map()]
  def open do
    from(a in ShareAlert,
      join: ls in "live_strategies",
      on: ls.id == a.live_strategy_id,
      join: s in "strategies",
      on: s.id == ls.strategy_id,
      where: a.status == "open",
      order_by: [asc: a.day, asc: a.id],
      select: {a, s.name}
    )
    |> Repo.all()
    |> Enum.map(fn {alert, name} -> %{alert: alert, name: name} end)
  end

  @doc """
  Log what you did about an alert: `params` from the Log trade form
  (`"account"`, `"shares"`, `"price"`, `"filled_at"` as typed in your time
  zone, `"cash"`: the account's cash change). The account's holdings and
  cash change with it (`Opus.Accounts.apply_fill/2`), then the alert counts
  as filled. `{:error, words}` when something doesn't read.
  """
  @spec log_fill(integer(), map()) :: {:ok, ShareAlert.t()} | {:error, String.t()}
  def log_fill(id, params) do
    with %ShareAlert{status: "open"} = alert <- Repo.get(ShareAlert, id),
         {:ok, fill} <- read_fill(alert, params),
         {:ok, _overview, _added} <- Accounts.apply_fill(fill.account, Map.delete(fill, :account)),
         {:ok, alert} <-
           alert
           |> Ecto.Changeset.change(
             status: "filled",
             filled_shares: fill.shares,
             filled_price: fill.price,
             filled_at: fill.filled_at,
             account: fill.account
           )
           |> Repo.update() do
      Feed.changed()
      {:ok, alert}
    else
      nil -> {:error, "That alert isn't there any more."}
      %ShareAlert{} -> {:error, "That alert was already logged."}
      {:error, %Ecto.Changeset{}} -> {:error, "The log couldn't be saved."}
      {:error, words} when is_binary(words) -> {:error, words}
      {:error, reason} -> {:error, "The accounts couldn't be saved: #{inspect(reason)}"}
    end
  end

  @doc "You didn't act on the alert: it counts as not traded."
  @spec skip(integer()) :: {:ok, ShareAlert.t()} | {:error, String.t()}
  def skip(id) do
    case Repo.get(ShareAlert, id) do
      %ShareAlert{status: "open"} = alert ->
        {:ok, alert} = alert |> Ecto.Changeset.change(status: "skipped") |> Repo.update()
        Feed.changed()
        {:ok, alert}

      _other ->
        {:error, "That alert isn't waiting for a log."}
    end
  end

  @doc "The Log trade form's starting values: the alert's numbers, filled at its time."
  @spec form_defaults(ShareAlert.t(), [String.t()]) :: map()
  def form_defaults(%ShareAlert{} = alert, accounts) do
    %{
      "account" => default_account(alert, accounts),
      "shares" => text(alert.shares),
      "price" => text(alert.price),
      "filled_at" => default_time(alert.day),
      "cash" => text(cash_change(alert.side, alert.shares, alert.price))
    }
  end

  # A sell comes out of the account that bought; a buy goes in
  # Non-registered unless there isn't one.
  defp default_account(%ShareAlert{side: "sell", live_strategy_id: id}, accounts) do
    case held([id]) do
      %{^id => %{account: account}} when is_binary(account) -> account
      _ -> default_account(%ShareAlert{side: "buy"}, accounts)
    end
  end

  defp default_account(_alert, accounts) do
    if "Non-registered" in accounts, do: "Non-registered", else: List.first(accounts)
  end

  # 15:50 New York on the alert's day, in your time zone, as the form's
  # datetime-local value.
  defp default_time(day) do
    day
    |> DateTime.new!(~T[15:50:00], Clock.market_zone())
    |> DateTime.shift_zone!(Clock.display_zone())
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  @doc "The account's cash change for a fill: a buy spends, a sale brings in."
  @spec cash_change(String.t(), number(), number()) :: float()
  def cash_change("buy", shares, price), do: Float.round(-shares * price, 2)
  def cash_change("sell", shares, price), do: Float.round(shares * price, 2)

  defp read_fill(alert, params) do
    with {:ok, account} <- present(params["account"], "Pick the account it was filled in."),
         {:ok, shares} <- positive(params["shares"], "Shares"),
         {:ok, price} <- positive(params["price"], "Price"),
         {:ok, cash} <- number(params["cash"], "Cash change"),
         {:ok, filled_at} <- filled_at(params["filled_at"]) do
      {:ok,
       %{
         account: account,
         side: alert.side,
         symbol: alert.symbol,
         shares: shares,
         price: price,
         cash: cash,
         filled_at: filled_at
       }}
    end
  end

  defp present(value, _words) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, words), do: {:error, words}

  defp positive(text, label) do
    case number(text, label) do
      {:ok, n} when n > 0 -> {:ok, n}
      {:ok, _} -> {:error, "#{label} must be more than 0."}
      error -> error
    end
  end

  defp number(text, label) do
    case text |> to_string() |> String.replace(~r/[,$\s]/, "") |> Float.parse() do
      {n, ""} -> {:ok, n}
      _ -> {:error, "#{label} isn't a number: #{text}"}
    end
  end

  defp filled_at(text) when is_binary(text) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(pad_seconds(text)),
         {:ok, local} <- DateTime.from_naive(naive, Clock.display_zone()) do
      {:ok, local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
    else
      _ -> {:error, "When it filled isn't a date and time: #{text}"}
    end
  end

  defp filled_at(_), do: {:error, "Say when it filled."}

  defp pad_seconds(text), do: if(String.length(text) == 16, do: text <> ":00", else: text)

  defp text(nil), do: ""

  defp text(n) when is_float(n),
    do: n |> Float.round(4) |> to_string() |> String.replace(~r/\.0$/, "")

  defp text(n), do: to_string(n)

  @doc "The Discord message for a check's alerts and the assignments it couldn't decide."
  @spec message([{ShareAlert.t(), assignment()}], [{assignment(), String.t()}]) ::
          {String.t(), [String.t()]}
  def message(alerts, unready) do
    lines =
      Enum.map(alerts, fn {alert, assignment} -> line(alert, assignment.name) end) ++
        Enum.map(unready, fn {a, why} -> "Couldn't check #{a.symbol} (#{a.name}): #{why}" end)

    {"Share alerts, #{Calendar.strftime(Clock.today(), "%b %-d")}",
     lines ++ ["Place them before the 16:00 close, then Log trade on the Dashboard."]}
  end

  @doc "One alert in a sentence: what to place, and the stop or the reason."
  @spec line(ShareAlert.t(), String.t()) :: String.t()
  def line(%ShareAlert{side: "buy"} = a, name) do
    "BUY #{text(a.shares)} #{a.symbol} at about #{price(a.price, a.currency)}, limit " <>
      "#{price(limit_price(a), a.currency)} (#{name}). Then set a stop at " <>
      "#{price(a.stop_price, a.currency)}."
  end

  def line(%ShareAlert{side: "sell"} = a, name) do
    "SELL #{text(a.shares)} #{a.symbol} at about #{price(a.price, a.currency)}, limit " <>
      "#{price(limit_price(a), a.currency)} (#{name}): #{reason_words(a.reason)}."
  end

  @doc "Why a sell, in words."
  @spec reason_words(String.t() | nil) :: String.t()
  def reason_words("stop"), do: "the price reached the stop"
  def reason_words("time_stop"), do: "held as many days as the strategy allows"
  def reason_words("rule"), do: "the strategy's exit rule says sell"
  def reason_words(_), do: "the strategy says sell"

  defp price(nil, _currency), do: "—"

  defp price(p, currency),
    do:
      "$#{:erlang.float_to_binary(p / 1, decimals: 2)}#{if currency == "USD", do: " US", else: ""}"

  defp send_alerts([], []), do: :ok

  defp send_alerts(alerts, unready) do
    if Discord.configured?() do
      {title, lines} = message(alerts, unready)

      with {:error, reason} <- Discord.post_message(title, lines) do
        Logger.warning("[ShareAlerts] Discord post failed: #{inspect(reason)}")
      end
    end

    :ok
  end
end
