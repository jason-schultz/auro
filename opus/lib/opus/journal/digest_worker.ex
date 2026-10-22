defmodule Opus.Journal.DigestWorker do
  @moduledoc """
  Monday job: freeze last week's Journal numbers into `weekly_digests`.

  Idempotent per week (upsert on `week_start`), so re-running after a missed
  Monday or a restart is safe. Also callable by hand for any week:

      Opus.Journal.DigestWorker.generate(~D[2026-10-12])
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias Opus.Journal
  alias Opus.Journal.Digest
  alias Opus.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    week_start =
      case args do
        %{"week_start" => iso} -> Date.from_iso8601!(iso)
        _ -> DateTime.utc_now() |> Digest.previous_week() |> elem(0)
      end

    case generate(week_start) do
      {:ok, digest} ->
        Logger.info(
          "[Digest] Week of #{digest.week_start}: #{digest.payload["kpis"]["trade_count"]} trades, " <>
            "P&L #{digest.payload["kpis"]["total_pnl_cad"]} CAD"
        )

        :ok

      {:error, reason} ->
        Logger.error("[Digest] Failed for week of #{week_start}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Build and upsert the digest for the Monday-to-Sunday week starting on `week_start`."
  @spec generate(Date.t()) :: {:ok, Digest.t()} | {:error, term()}
  def generate(%Date{} = week_start) do
    week_end = Date.add(week_start, 6)
    from_ts = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")
    to_ts = DateTime.new!(week_end, ~T[23:59:59.999999], "Etc/UTC")
    window = {from_ts, to_ts}

    payload = %{
      "kpis" => Journal.kpis(window),
      "strategies" => Journal.strategy_performance(window),
      "execution_quality" => Journal.execution_quality(window)
    }

    %Digest{}
    |> Digest.changeset(%{
      week_start: week_start,
      week_end: week_end,
      payload: payload,
      generated_at: DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: {:replace, [:week_end, :payload, :generated_at]},
      conflict_target: :week_start,
      returning: true
    )
  end
end
