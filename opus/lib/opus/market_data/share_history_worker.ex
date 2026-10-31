defmodule Opus.MarketData.ShareHistoryWorker do
  @moduledoc """
  Gets a market tested as shares owned outright ready to test, in the
  background, when it's added or its test broker is set to one that holds
  shares (`Opus.Instruments.add/2`, `Opus.Instruments.set_broker/2`):

    1. its daily bars from Questrade back to `@from`, in windows of
       `@window_days` (Questrade bars are split-adjusted; the nightly feeds
       only keep the last few days current), unless it already has more
       than `@deep_days` of them;
    2. then its dividends (`Opus.Instruments.load_dividends/1`), when
       Massive covers it and they were never loaded. Bars first: a big
       payment the bars already price in is checked against them.

  All vendor calls go through the live engine. Idempotent: a re-run
  overwrites the same rows.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 3,
    unique: [keys: [:instrument_id], period: 3600]

  import Ecto.Query

  require Logger

  alias Opus.Auro.Client
  alias Opus.Instruments
  alias Opus.Instruments.Instrument
  alias Opus.Repo

  @from ~D[1995-01-01]
  @window_days 700
  @deep_days 3 * 365

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 10 * 60

  @doc "Queues the load for `instrument` when its tests hold shares."
  @spec enqueue(Instrument.t()) :: :ok
  def enqueue(%Instrument{test_broker: broker} = instrument) do
    if broker in Instruments.share_brokers(),
      do: {:ok, _job} = Oban.insert(new(%{instrument_id: instrument.id}))

    :ok
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"instrument_id" => id}}) do
    case Repo.get(Instrument, id) do
      nil -> :ok
      instrument -> with :ok <- history(instrument), do: dividends(instrument)
    end
  end

  defp history(%Instrument{questrade_symbol: nil}), do: :ok

  defp history(%Instrument{questrade_symbol: symbol}) do
    if deep?(symbol) do
      :ok
    else
      today = Opus.Clock.today()

      Stream.iterate(@from, &Date.add(&1, @window_days + 1))
      |> Enum.take_while(&(Date.compare(&1, today) != :gt))
      |> Enum.reduce_while(:ok, fn from, :ok ->
        to = Enum.min([Date.add(from, @window_days), today], Date)

        case Client.persist_questrade_window(symbol, "D", from, to) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:history, symbol, reason}}}
        end
      end)
      |> tap(&(&1 == :ok && Logger.info("[ShareHistory] Loaded #{symbol}'s daily history")))
    end
  end

  # Daily bars stored since more than `@deep_days` ago: the history is in.
  defp deep?(symbol) do
    cutoff = DateTime.new!(Date.add(Opus.Clock.today(), -@deep_days), ~T[00:00:00], "Etc/UTC")

    Repo.exists?(
      from(c in "candles",
        where: c.instrument == ^symbol and c.granularity == "D" and c.timestamp < ^cutoff
      )
    )
  end

  defp dividends(%Instrument{massive_ticker: nil}), do: :ok
  defp dividends(%Instrument{dividends_checked_at: %NaiveDateTime{}}), do: :ok

  defp dividends(%Instrument{massive_ticker: ticker}) do
    case Instruments.load_dividends(ticker) do
      {:ok, count} ->
        Logger.info("[ShareHistory] Loaded #{count} dividends for #{ticker}")
        :ok

      {:error, reason} ->
        {:error, {:dividends, ticker, reason}}
    end
  end
end
