defmodule Opus.Trading.SignalEventListener do
  @moduledoc """
  LISTEN/NOTIFY bridge from Postgres to Phoenix PubSub: the engine's
  `signal_event`s (topic `signals:feed`), and `live_trades_changed`, sent
  by a trigger when a live trade opens or closes (migration
  `20261031010000_notify_live_trade_changes`), which refreshes the
  dashboard (`Opus.Dashboard.Feed.changed/0`).
  """

  use GenServer
  require Logger

  @channel "signal_event"
  @topic "signals:feed"
  @trades_channel "live_trades_changed"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    repo_config = Opus.Repo.config()

    notif_opts =
      repo_config
      |> Keyword.take([:hostname, :port, :database, :username, :password, :ssl, :socket_options])
      |> Keyword.put_new(:auto_reconnect, true)

    case Postgrex.Notifications.start_link(notif_opts) do
      {:ok, pid} ->
        {:ok, ref} = Postgrex.Notifications.listen(pid, @channel)
        {:ok, _ref} = Postgrex.Notifications.listen(pid, @trades_channel)
        Logger.info("[SignalEventListener] Listening on NOTIFY #{@channel}, #{@trades_channel}")
        {:ok, %{notifications_pid: pid, ref: ref}}

      {:error, reason} ->
        Logger.error("[SignalEventListener] Failed to start notifications: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @trades_channel, _status}, state) do
    Opus.Dashboard.Feed.changed()
    {:noreply, state}
  end

  def handle_info({:notification, _pid, _ref, @channel, payload}, state) do
    case Jason.decode(payload) do
      {:ok, event} ->
        Phoenix.PubSub.broadcast(Opus.PubSub, @topic, {:signal_event, event})

      {:error, reason} ->
        Logger.warning("[SignalEventListener] Failed to decode payload: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
