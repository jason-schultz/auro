import Config

# Prod is the dev setup minus the developer tooling: no code reloader, live
# reload, watchers or debug pages, and assets served from the digested build
# (`mix assets.deploy`). The endpoint, database and secrets come from the
# environment in config/runtime.exs.
config :opus, OpusWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Configures Swoosh API Client
# config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Opus.Finch

# Disable Swoosh Local Memory Storage
# config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
