defmodule Opus.MarketData.DividendRecordWorker do
  @moduledoc """
  Records dividends as they come for markets tested as shares held that have
  no dividend history to load (Massive covers US listings only, so Canadian
  ones). Questrade knows only each listing's latest dividend, so once a
  trading day this asks for it and stores any payment not yet recorded
  (`dividends`, one row per ex-date). Their tests pay what's recorded and
  say that earlier dividends are left out (the engine's
  `dividends_recorded_since`); the record grows from here.

  Through the live engine, the single holder of the Questrade connection.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Opus.Auro.Client
  alias Opus.{Instruments, Repo}

  @batch 50

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 10 * 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{}) do
    markets = markets()

    markets
    |> Map.keys()
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Client.get_questrade_symbols(batch) do
        {:ok, %{"symbols" => symbols}} ->
          rows = rows(symbols, markets, DateTime.utc_now())

          Repo.insert_all("dividends", rows,
            on_conflict: :nothing,
            conflict_target: [:instrument_id, :ex_date]
          )

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> tap(&(&1 == :ok && Logger.info("[Dividends] Checked #{map_size(markets)} listings")))
  end

  @doc """
  Dividend rows from Questrade's symbol data: each listing in `markets`
  (Questrade symbol → instrument id) whose latest dividend has an amount
  and an ex-date.
  """
  @spec rows([map()], %{String.t() => integer()}, DateTime.t()) :: [map()]
  def rows(symbols, markets, now) do
    at = now |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

    for %{"requested" => ticker, "dividend" => cash, "ex_date" => ex} = s <- symbols,
        id = markets[ticker],
        is_integer(id),
        is_number(cash) and cash > 0,
        {:ok, ex_date} <- [date(ex)] do
      %{
        instrument_id: id,
        ex_date: ex_date,
        pay_date: with({:ok, d} <- date(s["dividend_date"]), do: d, else: (_ -> nil)),
        cash_amount: cash / 1,
        inserted_at: at,
        updated_at: at
      }
    end
  end

  # Questrade sends dates as ISO timestamps ("2026-09-26T00:00:00.000000-04:00").
  defp date(text) when is_binary(text) and byte_size(text) >= 10,
    do: Date.from_iso8601(binary_part(text, 0, 10))

  defp date(_text), do: :error

  # Markets tested as shares held with no dividend history to load.
  defp markets do
    from(i in "instruments",
      where:
        i.test_broker in ^Instruments.share_brokers() and is_nil(i.massive_ticker) and
          not is_nil(i.questrade_symbol),
      select: {i.questrade_symbol, i.id}
    )
    |> Repo.all()
    |> Map.new()
  end
end
