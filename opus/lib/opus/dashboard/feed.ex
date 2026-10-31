defmodule Opus.Dashboard.Feed do
  @moduledoc """
  Keeps the dashboard current for every open Dashboard page at once: one
  process gathers it (`Opus.Dashboard.gather/1`) and pushes the result on
  PubSub (`subscribe/0`, `{:dashboard, data}`), instead of each page
  re-reading on its own timer.

  It gathers again when something the dashboard shows has changed:

    * any background job finishing or failing (Oban telemetry): the paper
      books, option quotes, holdings prices, drift, pipeline stages and
      failed jobs all come from jobs;
    * a live trade opening or closing (`live_trades_changed` from
      Postgres, `Opus.Trading.SignalEventListener`);
    * a suspension or the account pause opening or clearing (`changed/0`).

  Changes that land together are gathered once, `@settle_ms` later. What
  can only be noticed by looking (the engine gone quiet, a candle or a NAV
  snapshot going stale) is caught by a gather every `@heartbeat_ms`. With
  no Dashboard open, it gathers nothing.
  """

  use GenServer

  alias Opus.Dashboard

  @topic "dashboard"
  @settle_ms 2_000
  @heartbeat_ms :timer.minutes(1)
  @job_events [[:oban, :job, :stop], [:oban, :job, :exception]]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribes the caller to each fresh gather: `{:dashboard, data}`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Opus.PubSub, @topic)

  @doc "Something the dashboard shows changed: gather again shortly."
  @spec changed() :: :ok
  def changed do
    if pid = Process.whereis(__MODULE__), do: send(pid, :changed)
    :ok
  end

  @impl true
  def init(_opts) do
    :telemetry.attach_many({__MODULE__, self()}, @job_events, &__MODULE__.job_done/4, nil)
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:ok, %{due: false}}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach({__MODULE__, self()})

  @doc false
  # Telemetry runs this in the job's own process; the gather stays here.
  def job_done(_event, _measure, _meta, _config), do: changed()

  @impl true
  def handle_info(:changed, %{due: true} = state), do: {:noreply, state}

  def handle_info(:changed, state) do
    Process.send_after(self(), :gather, @settle_ms)
    {:noreply, %{state | due: true}}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    handle_info(:changed, state)
  end

  # Nobody has the Dashboard open: nothing to gather for (a page gathers
  # for itself when it opens). Phoenix.PubSub keeps its subscribers in a
  # Registry under its own name.
  def handle_info(:gather, state) do
    if Registry.lookup(Opus.PubSub, @topic) != [] do
      Phoenix.PubSub.broadcast(Opus.PubSub, @topic, {:dashboard, Dashboard.gather()})
    end

    {:noreply, %{state | due: false}}
  end
end
