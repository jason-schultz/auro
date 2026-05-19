defmodule Opus.Trading.SignalEventListener do
  @moduledoc """
  LISTEN/NOTIFY bridge from Postgres `signal_event` to Phoenix PubSub.
  """

  use GenServer
  require Logger

  @channel "signal_event"
  @topic "signals:feed"

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
        Logger.info("[SignalEventListener] Listening on NOTIFY #{@channel}")
        {:ok, %{notifications_pid: pid, ref: ref}}

      {:error, reason} ->
        Logger.error("[SignalEventListener] Failed to start notifications: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
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
