defmodule Opus.MarketData.EventWindowSyncWorker do
  @moduledoc """
  Daily job: keeps every live strategy's `EventWindow` component supplied with
  current release times from its named calendar (`params.calendar`). Opus owns
  the calendar; Rust only consumes the `events` list. Updates go through
  Rust's live-strategy update endpoint, which re-validates the config.

  Only events from `@lookback_days` ago onward are pushed, so the list stays
  small while a window that opened before a release can still close.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.MarketData.MacroCalendar
  alias Opus.Repo
  alias Opus.Trading.LiveStrategy

  @lookback_days 7

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{}) do
    with {:ok, calendars} <- load_calendars() do
      now = DateTime.utc_now()

      failures =
        for s <- Repo.all(from(s in LiveStrategy)),
            {:changed, params} <- [refresh_parameters(s.parameters, calendars, now)],
            result =
              Client.update_live_strategy(s.id, %{
                strategy_type: s.strategy_type,
                instrument: s.instrument,
                granularity: s.granularity,
                parameters: params
              }),
            not match?({:ok, _}, result),
            do: {s.id, result}

      case failures do
        [] -> :ok
        _ -> {:error, {:event_sync_failed, failures}}
      end
    end
  end

  defp load_calendars do
    Enum.reduce_while(MacroCalendar.calendars(), {:ok, %{}}, fn name, {:ok, acc} ->
      case MacroCalendar.events(name) do
        {:ok, dts} -> {:cont, {:ok, Map.put(acc, name, dts)}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Pure core: given a strategy's parameters, the calendars and the current
  time, return `{:changed, new_params}` when any calendar-tagged
  `EventWindow` component's events differ from the calendar, else
  `:unchanged`. Components without a known calendar are left alone.
  """
  @spec refresh_parameters(map(), %{String.t() => [DateTime.t()]}, DateTime.t()) ::
          {:changed, map()} | :unchanged
  def refresh_parameters(%{"components" => components} = params, calendars, now)
      when is_map(components) do
    cutoff = DateTime.add(now, -@lookback_days * 86_400, :second)

    updated =
      Map.new(components, fn
        {name, %{"type" => "EventWindow", "params" => %{"calendar" => cal} = p} = comp}
        when is_map_key(calendars, cal) ->
          events =
            calendars
            |> Map.fetch!(cal)
            |> Enum.filter(&(DateTime.compare(&1, cutoff) != :lt))
            |> Enum.map(&DateTime.to_iso8601/1)

          {name, %{comp | "params" => Map.put(p, "events", events)}}

        other ->
          other
      end)

    if updated == components,
      do: :unchanged,
      else: {:changed, %{params | "components" => updated}}
  end

  def refresh_parameters(_params, _calendars, _now), do: :unchanged
end
