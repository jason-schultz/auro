defmodule OpusWeb.SignalsChannel do
  use OpusWeb, :channel

  @topic "signals:feed"

  @impl true
  def join("signals:feed", _payload, socket) do
    Phoenix.PubSub.subscribe(Opus.PubSub, @topic)
    {:ok, socket}
  end

  def join("signals:" <> _subtopic, _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info({:signal_event, event}, socket) do
    push(socket, "signal_event", event)
    {:noreply, socket}
  end
end
