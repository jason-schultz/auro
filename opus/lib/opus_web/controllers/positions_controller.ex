defmodule OpusWeb.PositionsController do
  use OpusWeb, :controller

  import Ecto.Query

  alias Opus.Repo

  def sparkline(conn, %{"trade_id" => trade_id} = params) do
    bars = parse_bars(Map.get(params, "bars"))

    with {:ok, %{instrument: instrument, entry_time: entry_time}} <- fetch_trade_context(trade_id) do
      rows =
        from(c in "candles",
          where:
            c.instrument == ^instrument and c.granularity == "M1" and c.timestamp >= ^entry_time,
          order_by: [desc: c.timestamp],
          limit: ^bars,
          select: [c.timestamp, c.open, c.high, c.low, c.close, c.volume]
        )
        |> Repo.all()
        |> Enum.reverse()

      candles =
        Enum.map(rows, fn [timestamp, open, high, low, close, volume] ->
          %{
            timestamp: timestamp,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume
          }
        end)

      json(conn, %{trade_id: trade_id, instrument: instrument, bars: bars, candles: candles})
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "trade not found"})
    end
  end

  defp parse_bars(nil), do: 60

  defp parse_bars(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= 500 -> n
      _ -> 60
    end
  end

  defp fetch_trade_context(trade_id) do
    case from(t in "live_trades",
           where: t.oanda_trade_id == ^trade_id,
           order_by: [desc: t.entry_time],
           limit: 1,
           select: %{instrument: t.instrument, entry_time: t.entry_time}
         )
         |> Repo.one() do
      %{instrument: instrument, entry_time: entry_time} ->
        {:ok, %{instrument: instrument, entry_time: normalize_entry_time(entry_time)}}

      nil ->
        {:error, :not_found}
    end
  end

  defp normalize_entry_time(%DateTime{} = entry_time), do: entry_time

  defp normalize_entry_time(%NaiveDateTime{} = entry_time),
    do: DateTime.from_naive!(entry_time, "Etc/UTC")
end
