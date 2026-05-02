import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :opus, Opus.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "opus_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :opus, OpusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "SGKhitM6jcnuwkZYigqzS9CaBuwrNnVzd19DuvS4iz7ccIZUE0uaAYbMPGaG0Vbb",
  server: false

# In test we don't send emails
# config :opus, Opus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
# config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :opus, Oban, testing: :manual
