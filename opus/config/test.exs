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

# Closed ports: anything that talks to the Rust engine (live or tester) fails
# fast in tests.
config :opus, auro_base_url: "http://127.0.0.1:3999", auro_tester_url: "http://127.0.0.1:3998"

config :opus, Oban, testing: :manual
config :opus, start_scheduled_workers: false, start_page_feeds: false

# Discord posts go to a Req.Test stub, never to a real channel.
config :opus, Opus.Dashboard.Discord,
  webhook_url: "https://discord.test/api/webhooks/1/test",
  req_options: [plug: {Req.Test, Opus.Dashboard.Discord}, retry: false]

# OANDA calls go to a Req.Test stub, never to the real account.
config :opus, Opus.Oanda.Client, req_options: [plug: {Req.Test, Opus.Oanda.Client}, retry: false]

# A fresh key for the saved secrets on every run (never a committed one),
# and the Settings page's tests answered by a Req.Test stub.
config :opus, :secrets_key, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

config :opus, Opus.Settings.Check,
  req_options: [plug: {Req.Test, Opus.Settings.Check}, retry: false]
