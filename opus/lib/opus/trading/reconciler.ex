defmodule Opus.Trading.Reconciler do
  @moduledoc """
  Periodically reconciles the `live_trades` table with OANDA's actual open trades.

  When OANDA closes a trade server-side (via stop loss or take profit), our database
  doesn't know about it. This GenServer runs every 60 seconds, compares what we think
  is open against what OANDA actually has open, and updates any stale rows.
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Oanda.Client, as: Oanda
  alias Opus.Repo
  alias Opus.Utils.Number, as: Number

  import Ecto.Query

  @reconcile_interval :timer.seconds(60)

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec last_run() :: DateTime.t() | nil
  def last_run, do: GenServer.call(__MODULE__, :last_run)

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    Logger.info(
      "[Reconciler] Trade reconciler started (#{div(@reconcile_interval, 1000)}s interval)"
    )

    # Schedule the first reconciliation after a short delay
    Process.send_after(self(), :reconcile, :timer.seconds(10))

    {:ok, %{last_run: nil, reconciled_count: 0}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    new_state =
      case reconcile() do
        {:ok, count} ->
          %{
            state
            | last_run: DateTime.utc_now(),
              reconciled_count: state.reconciled_count + count
          }

        {:error, reason} ->
          Logger.error("[Reconciler] Reconciliation failed: #{inspect(reason)}")
          state
      end

    # Schedule next run
    Process.send_after(self(), :reconcile, @reconcile_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

  # -- Core Reconciliation Logic --

  defp reconcile do
    # Step 1: Get all trades we think are open
    db_open_trades = get_db_open_trades()

    if Enum.empty?(db_open_trades) do
      {:ok, 0}
    else
      # Step 2: Get what OANDA actually has open
      case Oanda.get_open_trades() do
        {:ok, oanda_trades} ->
          oanda_trade_ids =
            oanda_trades
            |> Enum.map(& &1["id"])
            |> MapSet.new()

          # Step 3: Find trades open in DB but missing from OANDA
          stale_trades =
            Enum.reject(db_open_trades, fn trade ->
              MapSet.member?(oanda_trade_ids, trade.oanda_trade_id)
            end)

          # Step 4: Close each stale trade
          Enum.each(stale_trades, &close_stale_trade/1)

          {:ok, length(stale_trades)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_db_open_trades do
    query =
      from(t in "live_trades",
        left_join: s in "live_strategies",
        on: s.id == t.live_strategy_id,
        where: t.status == "open",
        select: %{
          id: t.id,
          oanda_trade_id: t.oanda_trade_id,
          live_strategy_id: t.live_strategy_id,
          instrument: t.instrument,
          direction: t.direction,
          entry_price: t.entry_price,
          strategy_type: s.strategy_type
        }
      )

    Repo.all(query)
  end

  defp close_stale_trade(trade) do
    Logger.info(
      "[Reconciler] Trade #{trade.oanda_trade_id} (#{trade.direction} #{trade.instrument}) " <>
        "was closed by OANDA. Fetching close details."
    )

    case fetch_close_details(trade) do
      {:ok, details} ->
        apply_close(trade, details)

      {:error, reason} ->
        Logger.warning(
          "[Reconciler] Skipping DB update for trade #{trade.oanda_trade_id} — " <>
            "will retry next tick. Reason: #{inspect(reason)}"
        )
    end
  end

  defp apply_close(trade, %{
         exit_price: exit_price,
         exit_reason: exit_reason,
         pnl: pnl,
         stop_loss_state_at_close: sl_state
       }) do
    now = DateTime.utc_now()

    case from(t in "live_trades",
           where: t.oanda_trade_id == ^trade.oanda_trade_id and t.status == "open"
         )
         |> Repo.update_all(
           set: [
             exit_price: exit_price,
             exit_time: now,
             pnl_percent: pnl,
             exit_reason: exit_reason,
             stop_loss_state_at_close: sl_state,
             status: "closed",
             updated_at: now
           ]
         ) do
      {1, _} ->
        Logger.info(
          "[Reconciler] Closed #{trade.direction} #{trade.instrument} @ #{Float.round(exit_price, 5)}, " <>
            "PnL=#{Float.round(pnl * 100, 4)}%, reason=#{exit_reason}, sl_state=#{sl_state || "nil"}"
        )

        Auro.delete_position(trade.oanda_trade_id)

      {0, _} ->
        Logger.warning("[Reconciler] No open trade found for #{trade.oanda_trade_id} to update")
    end
  end

  defp fetch_close_details(trade) do
    case Oanda.get_trade(trade.oanda_trade_id) do
      {:ok, trade_data} ->
        extract_close_details(trade, trade_data)

      {:error, {:http_error, 404, _body}} ->
        Logger.warning(
          "[Reconciler] Trade #{trade.oanda_trade_id} aged out of OANDA's trade list — " <>
            "falling back to transactions endpoint."
        )

        fetch_close_via_transactions(trade)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_close_via_transactions(trade) do
    with {:ok, close_tx} <- Oanda.find_close_transaction(trade.oanda_trade_id),
         {:ok, details} <- extract_close_from_transaction(trade, close_tx) do
      {:ok, details}
    end
  end

  defp extract_close_from_transaction(trade, close_tx) do
    exit_price = Number.parse_float(close_tx["exit_price"], 0.0)

    cond do
      exit_price <= 0.0 ->
        Logger.warning(
          "[Reconciler] Trade #{trade.oanda_trade_id}: transaction has " <>
            "exit_price=#{inspect(close_tx["exit_price"])}. " <>
            "Full data: #{inspect(close_tx)}"
        )

        {:error, :zero_exit_price}

      true ->
        realized_pl = Number.parse_float(close_tx["realized_pl"], 0.0)
        exit_reason = transaction_reason_to_label(close_tx["reason"])
        pnl = compute_pnl(trade.direction, trade.entry_price, exit_price, realized_pl)

        Logger.info(
          "[Reconciler] Trade #{trade.oanda_trade_id}: recovered close from transactions — " <>
            "exit_price=#{exit_price}, pnl=#{Float.round(pnl, 6)}, exit_reason=#{exit_reason}"
        )

        # No SL/TP order snapshot available via the transactions fallback path.
        {:ok,
         %{
           exit_price: exit_price,
           exit_reason: exit_reason,
           pnl: pnl,
           stop_loss_state_at_close: nil
         }}
    end
  end

  defp transaction_reason_to_label("STOP_LOSS_ORDER"), do: "StopLoss"
  defp transaction_reason_to_label("TAKE_PROFIT_ORDER"), do: "TakeProfit"
  defp transaction_reason_to_label("TRAILING_STOP_LOSS_ORDER"), do: "TrailingStop"
  defp transaction_reason_to_label("MARKET_ORDER_TRADE_CLOSE"), do: "ClosedByBroker"
  defp transaction_reason_to_label("MARKET_ORDER_POSITION_CLOSEOUT"), do: "ClosedByBroker"
  defp transaction_reason_to_label(_), do: "ClosedByBroker"

  defp extract_close_details(trade, %{"state" => "CLOSED"} = trade_data) do
    exit_price = Number.parse_float(trade_data["averageClosePrice"], 0.0)
    realized_pl = Number.parse_float(trade_data["realizedPL"], 0.0)
    exit_reason = determine_exit_reason(trade_data)

    cond do
      exit_price <= 0.0 ->
        Logger.warning(
          "[Reconciler] Trade #{trade.oanda_trade_id}: state=CLOSED but " <>
            "averageClosePrice=#{inspect(trade_data["averageClosePrice"])}, " <>
            "realizedPL=#{inspect(trade_data["realizedPL"])}, exit_reason=#{exit_reason}. " <>
            "Full response: #{inspect(trade_data)}"
        )

        {:error, :zero_exit_price}

      true ->
        pnl = compute_pnl(trade.direction, trade.entry_price, exit_price, realized_pl)
        sl_state = infer_stop_loss_state(trade, trade_data)

        Logger.info(
          "[Reconciler] Trade #{trade.oanda_trade_id}: extracted close details — " <>
            "exit_price=#{exit_price}, pnl=#{Float.round(pnl, 6)}, exit_reason=#{exit_reason}, " <>
            "sl_state=#{sl_state}"
        )

        {:ok,
         %{
           exit_price: exit_price,
           exit_reason: exit_reason,
           pnl: pnl,
           stop_loss_state_at_close: sl_state
         }}
    end
  end

  defp extract_close_details(trade, trade_data) do
    Logger.warning(
      "[Reconciler] Trade #{trade.oanda_trade_id}: expected state=CLOSED but got " <>
        "state=#{inspect(trade_data["state"])}. Full response: #{inspect(trade_data)}"
    )

    {:error, :not_closed}
  end

  defp compute_pnl("Long", entry, exit_price, _realized), do: (exit_price - entry) / entry
  defp compute_pnl("Short", entry, exit_price, _realized), do: (entry - exit_price) / entry
  defp compute_pnl(_, entry, _exit_price, realized), do: Number.safe_divide(realized, entry)

  # Infers the trade-management stop-loss state that was active at the moment
  # OANDA closed the trade. Mirrors the Initial / Breakeven / Trailing /
  # NotApplicable taxonomy that Rust writes for trades it closes itself
  # (see auro_be/src/engine/live/trade_management.rs).
  #
  # The OANDA trade response keeps the SL/TP/trailing order envelopes around
  # at close time with their final state (FILLED or CANCELLED). We classify
  # based on which envelope is present, falling back to comparing the stop
  # price to the entry price for the Initial-vs-Breakeven split.
  defp infer_stop_loss_state(trade, trade_data) do
    cond do
      trade[:strategy_type] != nil and trade.strategy_type != "trend_following" ->
        "NotApplicable"

      is_map(trade_data["trailingStopLossOrder"]) ->
        "Trailing"

      is_map(trade_data["stopLossOrder"]) ->
        sl_price = Number.parse_float(trade_data["stopLossOrder"]["price"], 0.0)
        entry = trade.entry_price || 0.0
        # 0.01% of entry price — same tolerance Rust's prefill uses to detect
        # a breakeven-shifted SL across instrument precisions.
        tolerance = entry * 0.0001

        if entry > 0.0 and abs(sl_price - entry) <= tolerance,
          do: "Breakeven",
          else: "Initial"

      true ->
        "NotApplicable"
    end
  end

  defp determine_exit_reason(trade_data) do
    cond do
      get_in(trade_data, ["stopLossOrder", "state"]) == "FILLED" ->
        "StopLoss"

      get_in(trade_data, ["takeProfitOrder", "state"]) == "FILLED" ->
        "TakeProfit"

      get_in(trade_data, ["trailingStopLossOrder", "state"]) == "FILLED" ->
        "TrailingStop"

      true ->
        "ClosedByBroker"
    end
  end
end
