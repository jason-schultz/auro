defmodule Opus.Trading.RegimeDetector do
  @moduledoc """
  Computes per-(instrument, granularity) regime classifications using indicator
  scalars from the Rust engine.

  Polls the Auro `/api/indicators` endpoint every 5 minutes for each
  (instrument, granularity) pair required by live strategies in the universe.
  The required granularities are derived from
  `Opus.Trading.Granularity.regime_frames_for_entry/1` so regime detection is
  entry-timeframe aware.

    * `:trending`  — ADX >= 30
    * `:choppy`    — ADX < 20
    * `:uncertain` — 20 <= ADX < 30
    * `:unknown`   — ADX is nil (insufficient data in the buffer)

  Choppy threshold follows Wilder's conventional `< 20` (instead of the
  stricter `< 15`) since "no trend" is the diagnostic, not "no movement at
  all."

  The classification map is held in GenServer state and read via `get_regime/2`
  or `get_all_regimes/0`. The future rules engine will consume this state to
  decide whether trend-following or mean-reverting strategies are allowed to
  fire on each (instrument, granularity).
  """

  use GenServer
  require Logger

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Support.Polling
  alias Opus.Trading.Granularity

  import Ecto.Query

  @poll_interval :timer.minutes(5)
  @initial_delay :timer.seconds(15)
  @fetch_timeout :timer.seconds(8)
  @fetch_max_concurrency 12

  @adx_trending 30.0
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

  @spec last_run() :: DateTime.t() | nil
  def last_run, do: GenServer.call(__MODULE__, :last_run)

  @doc "Runs one full regime detection sweep and returns the regime map."
  @spec detect_once() :: map()
  def detect_once do
    poll()
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    Logger.info("[RegimeDetector] Started (#{div(@poll_interval, 60_000)}min poll interval)")

    Polling.schedule(self(), @initial_delay)
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
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

  @impl true
  def handle_info(:poll, state) do
    regimes = detect_once()

    Logger.info(
      "[RegimeDetector] Poll #{state.poll_count + 1}: " <>
        "#{summarize(regimes)} across #{map_size(regimes)} pairs"
    )

    Polling.schedule(self(), @poll_interval)

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
    case active_strategy_targets() do
      [] ->
        Logger.info("[RegimeDetector] No active strategies to poll")
        %{}

      targets ->
        pairs =
          targets
          |> Enum.flat_map(fn {instrument, entry_granularity} ->
            Granularity.regime_frames_for_entry(entry_granularity)
            |> Enum.map(fn regime_granularity -> {instrument, regime_granularity} end)
          end)
          |> Enum.uniq()

        pairs
        |> Task.async_stream(
          &fetch_regime_pair/1,
          max_concurrency: @fetch_max_concurrency,
          timeout: @fetch_timeout,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.reduce(%{}, fn
          {:ok, {{instrument, granularity}, data}}, acc ->
            Map.put(acc, {instrument, granularity}, data)

          {:ok, nil}, acc ->
            acc

          {:exit, reason}, acc ->
            Logger.debug("[RegimeDetector] indicator fetch task exited: #{inspect(reason)}")
            acc
        end)
    end
  end

  defp fetch_regime_pair({instrument, granularity}) do
    case Auro.get_indicators(instrument, granularity) do
      {:ok, response} ->
        {{instrument, granularity}, classify(response)}

      {:error, _reason} ->
        # No buffer for this granularity — skip silently
        nil
    end
  end

  defp active_strategy_targets do
    from(s in "live_strategies",
      distinct: [s.instrument, s.granularity],
      select: {s.instrument, s.granularity}
    )
    |> Repo.all()
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
