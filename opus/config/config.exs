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

# New York time for the US market schedule (Oban cron, market dates).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configures the endpoint
config :opus, OpusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpusWeb.ErrorHTML, json: OpusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Opus.PubSub,
  live_view: [signing_salt: "RIZ9TVqD"]

config :opus, Oban,
  repo: Opus.Repo,
  plugins: [
    Oban.Plugins.Lifeline,
    # UTC. 23:30 UTC is after the 16:00 ET close in both EDT and EST; the
    # worker's overlapping re-fetch picks up any post-market bars it misses.
    {Oban.Plugins.Cron,
     crontab: [
       {"30 23 * * 1-5", Opus.MarketData.QuestradeBarsWorker},
       # 01:30 UTC Tue–Sat: the US daily bars for the session that just closed
       # (one job per symbol). Rust treats a daily bar as final once extended
       # hours end at 20:00 New York, which is 00:00/01:00 UTC by season.
       {"30 1 * * 2-6", Opus.MarketData.MassiveBarsWorker},
       # US options, New York time on trading days: a chain snapshot and
       # ideas scan before the open (yesterday's closing quotes, a heads-up),
       # then a snapshot on live quotes once the opening rush has settled, the
       # scan again, and the paper books (research/options_paper_engine.md).
       {"0 9 * * 1-5", Opus.MarketData.OptionsChainWorker, timezone: "America/New_York"},
       {"15 9 * * 1-5", Opus.Options.ScanWorker, timezone: "America/New_York"},
       {"0 10 * * 1-5", Opus.MarketData.OptionsChainWorker, timezone: "America/New_York"},
       {"15 10 * * 1-5", Opus.Options.ScanWorker, timezone: "America/New_York"},
       {"30 10 * * 1-5", Opus.Options.PaperWorker, timezone: "America/New_York"},
       # Every 15 minutes in the session: quote the paper books' open legs and
       # fill take-profits as resting orders would (Opus.Options.IntradayWorker).
       {"*/15 10-15 * * 1-5", Opus.Options.IntradayWorker, timezone: "America/New_York"},
       # 20:30 UTC is before the 17:00 New York rollover (21:00/22:00 UTC) the
       # day's financing rates apply to.
       {"30 20 * * 1-5", Opus.MarketData.FinancingSnapshotWorker},
       # Daily; also keeps newly created event strategies current within a day.
       {"15 0 * * *", Opus.MarketData.EventWindowSyncWorker},
       # Monday 12:00 UTC (08:00 ET): snapshot last week's forward-test numbers.
       {"0 12 * * 1", Opus.Journal.DigestWorker},
       # Dashboard alerts to Discord: new ones every 5 minutes, and a check-in
       # after the US close so a quiet day still says it was quiet.
       {"*/5 * * * *", Opus.Dashboard.NotifyWorker},
       {"30 16 * * 1-5", Opus.Dashboard.NotifyWorker,
        args: %{check_in: true}, timezone: "America/New_York"}
     ]}
  ],
  queues: [pipeline: 2, market_data: 1, alerts: 1]

# Which instruments each feed stores is a flag on the `instruments` table
# (the Instruments page); config keeps only the feed parameters.

# Questrade intraday bars persisted daily via Rust for the listings flagged
# `feed_questrade_bars`.
config :opus, Opus.MarketData.QuestradeBarsWorker,
  days: 5,
  granularities: ["M1", "M5"]

# Option chain snapshots from Questrade via Rust: near-the-money contracts
# for the next weeks on the listings flagged `feed_options_chain`, quoted
# nightly with the exchange greeks. Flag only names the owner would accept
# being assigned.
config :opus, Opus.Options.ScanWorker, enabled: true

# The options paper book (research/options_paper_engine.md): the wheel on
# these underlyings, in USD, one position each. Commission per contract:
# Wealthsimple charges none; ~$0.07 of exchange fees rounded up.
config :opus, Opus.Options.PaperWorker, enabled: true

# Each paper book is its own US$100,000 (research/options_paper_engine.md).
# Ideas (and ideas_half) trade whatever the nightly scan flags, on any stored chain.
config :opus, Opus.Options.Paper,
  books: %{
    "wheel" => ~w(SPY IWM),
    "put_spread" => ~w(SPY IWM QQQ),
    "iron_condor" => ~w(SPY IWM QQQ),
    "crash_puts" => ~w(SPY),
    "crash_puts_half" => ~w(SPY)
  },
  starting_cash: 100_000.0,
  commission: 0.10

# 20% either side of spot: the iron condor's −0.05 delta put wings sit
# further out than 10% (research/options_paper_engine.md, v2).
config :opus, Opus.MarketData.OptionsChainWorker,
  enabled: true,
  max_days_to_expiry: 45,
  strike_band_pct: 0.20

# US equity daily bars from Massive via Rust for the listings flagged
# `feed_massive_daily`. US intraday stays with the Questrade worker.
config :opus, Opus.MarketData.MassiveBarsWorker,
  days: 7,
  granularities: ["D"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
# config :opus, Opus.Mailer, adapter: Swoosh.Adapters.Local

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  opus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  opus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
