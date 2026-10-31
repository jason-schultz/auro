defmodule Opus.MarketData.SpreadWorker do
  @moduledoc """
  Measures what a round trip costs in spread for each market tested as
  shares owned outright (its test broker charges no overnight cost), so its
  tests charge its own spread instead of the broker's placeholder.

  `%{"step" => "sample"}`, every 15 minutes from 10:00 to 15:45 New York on
  trading days (away from the open's and close's wide quotes): Questrade's
  bid and ask for each, stored in `spread_samples` as (ask − bid) / mid in
  basis points. Halted quotes and one-sided books are skipped.

  `%{"step" => "settle"}`, after the close: each market's
  `instruments.spread_bps` becomes the median of its samples from the last
  `@window_days` days, once it has `@min_samples` (about two sessions);
  samples older than `@keep_days` are dropped.

  All Questrade access goes through the live engine (the single holder of
  the token).
  """

  use Oban.Worker, queue: :market_data, max_attempts: 1, unique: [period: 600]

  import Ecto.Query

  require Logger

  alias Opus.Auro.Client
  alias Opus.{Clock, Instruments, MarketCalendar, Repo}

  @batch 50
  @first ~T[10:00:00]
  @last ~T[15:45:00]
  @window_days 30
  @min_samples 40
  @keep_days 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"step" => "settle"}}) do
    {updated, _} = settle(DateTime.utc_now())
    Logger.info("[Spreads] Set #{updated} markets' measured spread")
    :ok
  end

  def perform(%Oban.Job{args: %{"step" => "sample"}, scheduled_at: at}) do
    if sampling?(at), do: sample(DateTime.utc_now()), else: :ok
  end

  @doc "Whether `utc` is in the sampling window on a trading day, to the second."
  @spec sampling?(DateTime.t()) :: boolean()
  def sampling?(utc) do
    local = Clock.local(utc)
    time = local |> DateTime.to_time() |> Time.truncate(:second)

    MarketCalendar.trading_day?(DateTime.to_date(local)) and
      Time.compare(time, @first) != :lt and Time.compare(time, @last) != :gt
  end

  defp sample(now) do
    markets = markets()

    results =
      markets
      |> Map.keys()
      |> Enum.chunk_every(@batch)
      |> Enum.map(fn batch ->
        with {:ok, %{"quotes" => quotes}} <- Client.get_questrade_quotes(batch) do
          rows = rows(quotes, markets, now)
          Repo.insert_all("spread_samples", rows)
          {:ok, length(rows)}
        end
      end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] ->
        :ok

      failed ->
        Logger.warning("[Spreads] #{length(failed)} quote batches failed: #{inspect(failed)}")
        {:error, {:failed_batches, length(failed)}}
    end
  end

  @doc """
  Sample rows from the engine's quotes: each quote with a two-sided,
  unhalted book, for a ticker in `markets` (Questrade symbol → instrument id).
  """
  @spec rows([map()], %{String.t() => integer()}, DateTime.t()) :: [map()]
  def rows(quotes, markets, now) do
    for %{"requested" => ticker, "bid_price" => bid, "ask_price" => ask} = q <- quotes,
        id = markets[ticker],
        is_integer(id),
        q["is_halted"] != true,
        is_number(bid) and is_number(ask) and bid > 0 and ask >= bid do
      %{
        instrument_id: id,
        captured_at: DateTime.truncate(now, :second),
        bid: bid / 1,
        ask: ask / 1,
        spread_bps: (ask - bid) / ((ask + bid) / 2) * 10_000
      }
    end
  end

  # Markets tested as shares owned outright, by Questrade symbol.
  defp markets do
    from(i in "instruments",
      where: i.test_broker in ^Instruments.share_brokers() and not is_nil(i.questrade_symbol),
      select: {i.questrade_symbol, i.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Sets each market's `spread_bps` to the median of its recent samples (with
  enough of them) and drops old samples. Returns the markets updated.
  """
  @spec settle(DateTime.t()) :: {non_neg_integer(), nil}
  def settle(now) do
    since = DateTime.add(now, -@window_days * 86_400)

    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE instruments i SET spread_bps = m.median
        FROM (
          SELECT instrument_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY spread_bps) AS median
          FROM spread_samples
          WHERE captured_at >= $1
          GROUP BY instrument_id
          HAVING count(*) >= $2
        ) m
        WHERE i.id = m.instrument_id
        """,
        [since, @min_samples]
      )

    from(s in "spread_samples",
      where: s.captured_at < ^DateTime.add(now, -@keep_days * 86_400)
    )
    |> Repo.delete_all()

    {updated, nil}
  end
end
