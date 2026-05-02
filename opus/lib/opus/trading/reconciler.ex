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
        where: t.status == "open",
        select: %{
          id: t.id,
          oanda_trade_id: t.oanda_trade_id,
          live_strategy_id: t.live_strategy_id,
          instrument: t.instrument,
          direction: t.direction,
          entry_price: t.entry_price
        }
      )

    Repo.all(query)
  end

  defp close_stale_trade(trade) do
    Logger.info(
      "[Reconciler] Trade #{trade.oanda_trade_id} (#{trade.direction} #{trade.instrument}) " <>
        "was closed by OANDA. Updating database."
    )

    {exit_price, exit_reason, pnl} = fetch_close_details(trade)

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
             status: "closed",
             updated_at: now
           ]
         ) do
      {1, _} ->
        Logger.info(
          "[Reconciler] Closed #{trade.direction} #{trade.instrument} @ #{Float.round(exit_price, 5)}, " <>
            "PnL=#{Float.round(pnl * 100, 4)}%, reason=#{exit_reason}"
        )

        Auro.delete_position(trade.oanda_trade_id)

      {0, _} ->
        Logger.warning("[Reconciler] No open trade found for #{trade.oanda_trade_id} to update")
    end
  end

  defp fetch_close_details(trade) do
    case Oanda.get_trade(trade.oanda_trade_id) do
      {:ok, trade_data} ->
        exit_price = Number.parse_float(trade_data["averageClosePrice"], 0.0)
        realized_pl = Number.parse_float(trade_data["realizedPL"], 0.0)
        exit_reason = determine_exit_reason(trade_data)

        pnl =
          if exit_price > 0.0 do
            case trade.direction do
              "Long" -> (exit_price - trade.entry_price) / trade.entry_price
              "Short" -> (trade.entry_price - exit_price) / trade.entry_price
              _ -> Number.safe_divide(realized_pl, trade.entry_price)
            end
          else
            Number.safe_divide(realized_pl, trade.entry_price)
          end

        {exit_price, exit_reason, pnl}

      {:error, reason} ->
        Logger.warning(
          "[Reconciler] Could not fetch trade #{trade.oanda_trade_id} details: #{inspect(reason)}. " <>
            "Marking as closed with unknown exit."
        )

        {0.0, "ClosedByBroker", 0.0}
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
