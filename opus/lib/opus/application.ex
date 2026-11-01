defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = base_children() ++ scheduled_workers() ++ page_feeds()
    Opus.Pipeline.Events.attach()

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

  # The processes that act on the account: syncing closed trades, pushing
  # the safety rules to the engine, tripping circuit breakers. Exactly one
  # Opus runs them, the service; a dev Opus beside it doesn't (config/dev.exs).
  defp scheduled_workers do
    if Application.get_env(:opus, :start_scheduled_workers, true) do
      [
        Opus.Trading.Reconciler,
        Opus.Trading.RulesEngine,
        Opus.Trading.CircuitBreaker
      ]
    else
      []
    end
  end

  # What keeps open pages current (Postgres notifications, the dashboard's
  # gather): read-only, so a dev Opus runs them too.
  defp page_feeds do
    if Application.get_env(:opus, :start_page_feeds, true) do
      [Opus.Trading.SignalEventListener, Opus.Dashboard.Feed]
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
