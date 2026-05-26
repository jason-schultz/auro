defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = base_children() ++ scheduled_workers()

    opts = [strategy: :one_for_one, name: Opus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp base_children do
    [
      OpusWeb.Telemetry,
      Opus.Repo,
      {DNSCluster, query: Application.get_env(:opus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Opus.PubSub},
      {Oban, Application.fetch_env!(:opus, Oban)},

      # Start the Finch HTTP client for sending emails (or other HTTP)
      {Finch, name: Opus.Finch},

      # Start the Phoenix endpoint (must be last)
      OpusWeb.Endpoint
    ]
  end

  defp scheduled_workers do
    if Application.get_env(:opus, :start_scheduled_workers, true) do
      [
        # Trading services
        Opus.Trading.Reconciler,
        Opus.Trading.RegimeDetector,
        Opus.Trading.RulesEngine,
        Opus.Trading.StrategyCurator,
        Opus.Trading.CircuitBreaker,
        Opus.Trading.SignalEventListener
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
