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

# The viewer's time zone: the pages show times in it (`Opus.Clock.display_zone/0`).
# Market schedule facts (the 16:00 close, the 10:00 chain) stay in New York.
config :opus, :display_zone, "America/Edmonton"

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
    # Delete finished jobs (completed, cancelled, discarded) after two weeks;
    # Oban keeps them forever otherwise. The dashboard only reads the last day.
    {Oban.Plugins.Pruner, max_age: {14, :days}},
    {Oban.Plugins.Cron,
     crontab: [
       # 20:30 New York, after extended hours end at 20:00, so the day's
       # daily bar is final; the overlapping re-fetch picks up anything missed.
       {"30 20 * * 1-5", Opus.MarketData.QuestradeBarsWorker, timezone: "America/New_York"},
       # Every 15 minutes in the session: re-price the Wealthsimple holdings
       # from Questrade quotes (Opus.Accounts.HoldingsPriceWorker).
       {"*/15 9-16 * * 1-5", Opus.Accounts.HoldingsPriceWorker, timezone: "America/New_York"},
       # The holdings at the close, after the 16:00 re-price (Opus.Accounts.SnapshotWorker).
       {"10 16 * * 1-5", Opus.Accounts.SnapshotWorker, timezone: "America/New_York"},
       # 15:45 New York: what each share-alert assignment says, 15 minutes
       # before the close it was tested on (Opus.Trading.ShareAlertWorker).
       {"45 15 * * 1-5", Opus.Trading.ShareAlertWorker, timezone: "America/New_York"},
       # Spreads of markets tested as shares held (Opus.MarketData.SpreadWorker):
       # sampled every 15 minutes mid-session, settled after the close.
       {"*/15 10-15 * * 1-5", Opus.MarketData.SpreadWorker,
        args: %{step: "sample"}, timezone: "America/New_York"},
       {"20 16 * * 1-5", Opus.MarketData.SpreadWorker,
        args: %{step: "settle"}, timezone: "America/New_York"},
       # The latest dividend of each listing with no dividend history to load
       # (Opus.MarketData.DividendRecordWorker), recorded as it comes.
       {"40 20 * * 1-5", Opus.MarketData.DividendRecordWorker, timezone: "America/New_York"},
       # 07:00 New York Tue–Sat: the US daily bars for the previous session
       # (one job per symbol). Massive's free plan publishes a session's bar
       # some time the next day, so the old evening run stored day D only on
       # D+2; this lands it before the 09:15 ideas scan reads it. The run
       # takes ~27 minutes on its own `massive` queue.
       {"0 7 * * 2-6", Opus.MarketData.MassiveBarsWorker, timezone: "America/New_York"},
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
       # 17:15 New York on trading days, after the close: each live strategy
       # against its backtest (Opus.Trading.DriftWorker).
       {"15 17 * * 1-5", Opus.Trading.DriftWorker, timezone: "America/New_York"},
       # Monday 12:00 UTC (08:00 ET): snapshot last week's forward-test numbers.
       {"0 12 * * 1", Opus.Journal.DigestWorker},
       # Dashboard alerts to Discord: new ones every 5 minutes; the day's
       # write-up after the US close (so a quiet day still says it was
       # quiet), and the week's on Friday.
       {"*/5 * * * *", Opus.Dashboard.NotifyWorker},
       {"30 16 * * 1-5", Opus.Dashboard.NotifyWorker,
        args: %{check_in: true}, timezone: "America/New_York"},
       {"0 17 * * 5", Opus.Dashboard.NotifyWorker,
        args: %{summary: "week"}, timezone: "America/New_York"}
     ]}
  ],
  queues: [pipeline: 2, market_data: 1, massive: 1, alerts: 1]

# Which instruments each feed stores is a flag on the `instruments` table
# (the Instruments page); config keeps only the feed parameters.

# Questrade intraday bars persisted daily via Rust for the listings flagged
# `feed_questrade_bars` and the Wealthsimple holdings (daily bars too for
# holdings no other feed covers).
config :opus, Opus.MarketData.QuestradeBarsWorker,
  days: 5,
  granularities: ["M1", "M5"],
  daily_days: 400

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
