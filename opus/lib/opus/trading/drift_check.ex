defmodule Opus.Trading.DriftCheck do
  @moduledoc """
  The latest check of a live strategy's real trades against its backtest
  (`Opus.Trading.Drift`), one row per strategy, replaced each time it runs:
  daily after the US close (`Opus.Trading.DriftWorker`) or from the
  strategy's page.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Repo
  alias Opus.Trading.{Drift, ExecutionQuality, LiveStrategy, LiveTrade, Strategies}

  @primary_key {:live_strategy_id, Ecto.UUID, autogenerate: false}
  schema "strategy_drift_checks" do
    field :verdict, :string
    field :live_trades, :integer
    field :findings, {:array, :map}
    field :checked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The latest check per strategy id, for the ids given."
  @spec latest([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => t()}
  def latest(ids) do
    from(c in __MODULE__, where: c.live_strategy_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.live_strategy_id, &1})
  end

  @doc """
  Check one strategy now and store the result. Needs the engine for the
  backtest's trades.
  """
  @spec run(LiveStrategy.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def run(%LiveStrategy{} = strategy, now \\ DateTime.utc_now()) do
    with {:ok, body} <- Client.backtest_trades(Strategies.engine_parameters(strategy)) do
      live = closed_trades(strategy.id)
      result = Drift.check(live, strategy.created_at, backtest(body), fills(strategy.id), now)

      %__MODULE__{live_strategy_id: strategy.id}
      |> Ecto.Changeset.change(
        verdict: Atom.to_string(result.verdict),
        live_trades: result.live_trades,
        # Stored as JSON, so string keys and values from the start: the
        # row reads the same just saved as loaded later.
        findings:
          Enum.map(result.findings, &Map.new(&1, fn {k, v} -> {to_string(k), to_string(v)} end)),
        checked_at: now
      )
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:inserted_at]},
        conflict_target: :live_strategy_id
      )
    end
  end

  defp closed_trades(id) do
    from(t in LiveTrade,
      where: t.live_strategy_id == ^id and t.status == "closed" and not is_nil(t.pnl_percent),
      order_by: [asc: t.exit_time],
      select: %{pnl: t.pnl_percent}
    )
    |> Repo.all()
  end

  defp backtest(%{"trades" => trades, "from" => from, "to" => to}) do
    %{trades: Enum.map(trades, &%{pnl: &1["pnl_percent"]}), from: at(from), to: at(to)}
  end

  defp fills(id) do
    from(t in LiveTrade,
      where: t.live_strategy_id == ^id and not is_nil(t.expected_entry_price),
      select: %{
        live_strategy_id: t.live_strategy_id,
        direction: t.direction,
        entry_price: t.entry_price,
        exit_price: t.exit_price,
        expected_entry_price: t.expected_entry_price,
        entry_spread: t.entry_spread,
        expected_exit_price: t.expected_exit_price,
        exit_spread: t.exit_spread
      }
    )
    |> Repo.all()
    |> ExecutionQuality.summarize()
    |> List.first()
  end

  defp at(text) do
    {:ok, at, _} = DateTime.from_iso8601(text)
    at
  end
end
