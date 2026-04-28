# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :opus,
  ecto_repos: [Opus.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :opus, OpusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: OpusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Opus.PubSub,
  live_view: [signing_salt: "RIZ9TVqD"]

config :opus, Oban,
  repo: Opus.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     timezone: "Etc/UTC",
     crontab: [
       {"0 * * * *", Opus.Trading.EvaluationWorker, args: %{granularity: "H1"}},
       {"*/15 * * * *", Opus.Trading.EvaluationWorker, args: %{granularity: "M15"}}
     ]}
  ],
  queues: [evaluations: 2]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
# config :opus, Opus.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
