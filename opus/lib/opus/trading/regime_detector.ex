defmodule Opus.Trading.RegimeDetector do
  @moduledoc """
  Computes per-(instrument, granularity) regime classifications using indicator
  scalars from the Rust engine.

  Polls the Auro `/api/indicators` endpoint every 5 minutes for each
  (instrument, granularity) pair with an enabled `live_strategies` row.
  Classifies each pair as:

    * `:trending`  — ADX >= 25
    * `:choppy`    — ADX < 20
    * `:uncertain` — 20 <= ADX < 25 (avoid trading either side)
    * `:unknown`   — ADX is nil (insufficient data in the buffer)

  The classification map is held in GenServer state and read via `get_regime/2`
  or `get_all_regimes/0`. The future rules engine will consume this state to
  decide whether trend-following or mean-reverting strategies are allowed to
  fire on each (instrument, granularity).
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo

  import Ecto.Query

  @poll_interval :timer.minutes(5)
  @initial_delay :timer.seconds(15)

  @adx_trending 25.0
  @adx_choppy 20.0

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the regime data for a specific (instrument, granularity) pair, or
  `%{regime: :unknown}` if the pair has not been polled yet.
  """
  @spec get_regime(String.t(), String.t()) :: map()
  def get_regime(instrument, granularity) do
    GenServer.call(__MODULE__, {:get_regime, instrument, granularity})
  end

  @doc "Returns the full regime state map keyed by `{instrument, granularity}`."
  @spec get_all_regimes() :: map()
  def get_all_regimes do
    GenServer.call(__MODULE__, :get_all_regimes)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    Logger.info(
      "[RegimeDetector] Started (#{div(@poll_interval, 60_000)}min poll interval)"
    )

    Process.send_after(self(), :poll, @initial_delay)
    {:ok, %{last_run: nil, regimes: %{}, poll_count: 0}}
  end

  @impl true
  def handle_call({:get_regime, instrument, granularity}, _from, state) do
    regime = Map.get(state.regimes, {instrument, granularity}, %{regime: :unknown})
    {:reply, regime, state}
  end

  @impl true
  def handle_call(:get_all_regimes, _from, state) do
    {:reply, state.regimes, state}
  end

  @impl true
  def handle_info(:poll, state) do
    regimes = poll()

    Logger.info(
      "[RegimeDetector] Poll #{state.poll_count + 1}: " <>
        "#{summarize(regimes)} across #{map_size(regimes)} pairs"
    )

    Process.send_after(self(), :poll, @poll_interval)

    new_state = %{
      state
      | last_run: DateTime.utc_now(),
        regimes: regimes,
        poll_count: state.poll_count + 1
    }

    {:noreply, new_state}
  end

  # -- Core logic --

  defp poll do
    case active_strategy_pairs() do
      [] ->
        Logger.info("[RegimeDetector] No active strategies to poll")
        %{}

      pairs ->
        Enum.reduce(pairs, %{}, fn {instrument, granularity}, acc ->
          case Auro.get_indicators(instrument, granularity) do
            {:ok, response} ->
              Map.put(acc, {instrument, granularity}, classify(response))

            {:error, reason} ->
              Logger.warning(
                "[RegimeDetector] Skipping #{instrument} #{granularity}: " <>
                  inspect(reason)
              )

              acc
          end
        end)
    end
  end

  defp active_strategy_pairs do
    query =
      from(s in "live_strategies",
        where: s.enabled == true,
        distinct: true,
        select: {s.instrument, s.granularity}
      )

    Repo.all(query)
  end

  defp classify(response) do
    indicators = response["indicators"] || %{}
    adx = indicators["adx"]
    bandwidth = get_in(indicators, ["bollinger", "bandwidth_pct"])

    %{
      regime: classify_regime(adx),
      adx: adx,
      bandwidth_pct: bandwidth,
      last_close: response["last_close"],
      last_close_time: response["last_close_time"],
      buffer_size: response["buffer_size"],
      last_updated: DateTime.utc_now()
    }
  end

  defp classify_regime(nil), do: :unknown
  defp classify_regime(adx) when adx >= @adx_trending, do: :trending
  defp classify_regime(adx) when adx < @adx_choppy, do: :choppy
  defp classify_regime(_adx), do: :uncertain

  defp summarize(regimes) do
    regimes
    |> Map.values()
    |> Enum.frequencies_by(& &1.regime)
    |> Enum.map(fn {regime, count} -> "#{regime}=#{count}" end)
    |> Enum.join(", ")
  end
end
