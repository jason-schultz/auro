defmodule OpusWeb.AccountController do
  use OpusWeb, :controller

  import Ecto.Query

  alias Opus.Repo

  @default_resolution "15m"

  @doc """
  Cross-broker portfolio summary: OANDA (latest account snapshot) plus
  Wealthsimple accounts (positions valued at last refreshed price).

  All accounts are CAD today; `total_cad` sums account values directly.
  If a non-CAD account ever appears, it is still listed but excluded from
  the total (per-account `currency` tells the FE what it's looking at).
  """
  def portfolio_summary(conn, _params) do
    oanda = latest_oanda_snapshot()
    wealthsimple = wealthsimple_accounts()

    accounts = List.wrap(oanda) ++ wealthsimple

    total_cad =
      accounts
      |> Enum.filter(&(&1.currency == "CAD"))
      |> Enum.map(& &1.value)
      |> Enum.sum()

    json(conn, %{
      total_cad: total_cad,
      as_of: DateTime.utc_now(),
      accounts: accounts
    })
  end

  defp latest_oanda_snapshot do
    from(s in "account_snapshots",
      order_by: [desc: s.timestamp],
      limit: 1,
      select: %{
        nav: s.nav,
        balance: s.balance,
        unrealized_pl: s.unrealized_pl,
        currency: s.currency,
        open_position_count: s.open_position_count,
        timestamp: s.timestamp
      }
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      row ->
        %{
          broker: "oanda",
          label: "OANDA Practice",
          currency: row.currency,
          value: row.nav,
          balance: row.balance,
          unrealized_pl: row.unrealized_pl,
          open_positions: row.open_position_count,
          as_of: row.timestamp
        }
    end
  end

  defp wealthsimple_accounts do
    position_values =
      from(p in "wealthsimple_positions",
        group_by: p.account_id,
        select:
          {p.account_id,
           %{
             market_value:
               fragment(
                 "SUM(? * COALESCE(?, ?, 0))::float8",
                 p.shares,
                 p.current_price,
                 p.avg_cost
               ),
             positions: count(p.id),
             priced_at: max(p.updated_at)
           }}
      )
      |> Repo.all()
      |> Map.new()

    from(a in "wealthsimple_accounts",
      order_by: [asc: a.id],
      select: %{
        id: a.id,
        account_type: a.account_type,
        currency: a.currency,
        cash: a.cash,
        market_value: a.market_value,
        total_equity: a.total_equity,
        updated_at: a.updated_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn account ->
      positions = Map.get(position_values, account.id)

      market_value =
        case positions do
          %{market_value: mv} when is_float(mv) and mv > 0 -> mv
          _ -> account.market_value || 0.0
        end

      value = account.total_equity || (account.cash || 0.0) + market_value

      %{
        broker: "wealthsimple",
        label: account.account_type,
        currency: account.currency,
        value: value,
        cash: account.cash,
        market_value: market_value,
        open_positions: (positions && positions.positions) || 0,
        as_of: (positions && positions.priced_at) || account.updated_at
      }
    end)
  end

  def equity_curve(conn, params) do
    now = DateTime.utc_now()

    with {:ok, to_ts} <- parse_ts(Map.get(params, "to"), now),
         {:ok, from_ts} <-
           parse_ts(Map.get(params, "from"), DateTime.add(to_ts, -30 * 86_400, :second)),
         {:ok, resolution} <- parse_resolution(Map.get(params, "resolution", @default_resolution)) do
      rows = query_equity_curve(from_ts, to_ts, resolution)

      points =
        Enum.map(rows, fn [timestamp, nav, balance, unrealized_pl, margin_used] ->
          %{
            timestamp: timestamp,
            nav: nav,
            balance: balance,
            unrealized_pl: unrealized_pl,
            margin_used: margin_used
          }
        end)

      json(conn, %{
        points: points,
        from: from_ts,
        to: to_ts,
        resolution: Map.get(params, "resolution", @default_resolution)
      })
    else
      {:error, msg} ->
        conn
        |> put_status(400)
        |> json(%{error: msg})
    end
  end

  defp parse_ts(nil, fallback), do: {:ok, fallback}

  defp parse_ts(value, _fallback) do
    case DateTime.from_iso8601(value) do
      {:ok, ts, _offset} -> {:ok, ts}
      _ -> {:error, "invalid timestamp: #{value}"}
    end
  end

  defp parse_resolution("1m"), do: {:ok, :raw_minute}
  defp parse_resolution("5m"), do: {:ok, 300}
  defp parse_resolution("15m"), do: {:ok, 900}
  defp parse_resolution("1h"), do: {:ok, 3_600}
  defp parse_resolution("1d"), do: {:ok, 86_400}
  defp parse_resolution(other), do: {:error, "invalid resolution: #{other}"}

  defp query_equity_curve(from_ts, to_ts, :raw_minute) do
    from(s in "account_snapshots",
      where: s.timestamp >= ^from_ts and s.timestamp <= ^to_ts,
      order_by: [asc: s.timestamp],
      select: [s.timestamp, s.nav, s.balance, s.unrealized_pl, s.margin_used]
    )
    |> Repo.all()
  end

  defp query_equity_curve(from_ts, to_ts, bucket_seconds) do
    bucketed =
      from(s in "account_snapshots",
        where: s.timestamp >= ^from_ts and s.timestamp <= ^to_ts,
        select: %{
          timestamp: s.timestamp,
          nav: s.nav,
          balance: s.balance,
          unrealized_pl: s.unrealized_pl,
          margin_used: s.margin_used,
          bucket_ts:
            fragment(
              "to_timestamp(floor(extract(epoch FROM ?) / ?) * ?) AT TIME ZONE 'UTC'",
              s.timestamp,
              ^bucket_seconds,
              ^bucket_seconds
            )
        }
      )

    ranked =
      from(b in subquery(bucketed),
        select: %{
          timestamp: b.timestamp,
          nav: b.nav,
          balance: b.balance,
          unrealized_pl: b.unrealized_pl,
          margin_used: b.margin_used,
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY ? DESC)",
              b.bucket_ts,
              b.timestamp
            )
        }
      )

    from(r in subquery(ranked),
      where: r.rn == 1,
      order_by: [asc: r.timestamp],
      select: [r.timestamp, r.nav, r.balance, r.unrealized_pl, r.margin_used]
    )
    |> Repo.all()
  end
end
