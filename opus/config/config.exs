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
       # Option chain snapshots from Questrade after the close (02:00 UTC is
       # 21:00/22:00 New York): the quotes are the day's closing values.
       {"0 2 * * 2-6", Opus.MarketData.OptionsChainWorker},
       # 20:30 UTC is before the 17:00 New York rollover (21:00/22:00 UTC) the
       # day's financing rates apply to.
       {"30 20 * * 1-5", Opus.MarketData.FinancingSnapshotWorker},
       # Daily; also keeps newly created event strategies current within a day.
       {"15 0 * * *", Opus.MarketData.EventWindowSyncWorker},
       # Monday 12:00 UTC (08:00 ET): snapshot last week's forward-test numbers.
       {"0 12 * * 1", Opus.Journal.DigestWorker}
     ]}
  ],
  queues: [pipeline: 2, market_data: 1]

# Questrade intraday bars persisted daily via Rust. Tickers use Questrade's
# notation (.TO = TSX, .VN = TSX Venture, bare = US).
config :opus, Opus.MarketData.QuestradeBarsWorker,
  days: 5,
  granularities: ["M1", "M5"],
  watchlist: ~w(
    HIVE.TO HUT.TO DMGI.VN DML.TO NXE.TO EFR.TO EQX.TO IMG.TO OGC.TO WDO.TO
    KNT.TO ARIS.TO SVM.TO ERO.TO TKO.TO CS.TO LUN.TO FL.VN WELL.TO BB.TO
    WEED.TO OGI.TO ACB.TO BTE.TO ATH.TO CJ.TO OBE.TO TVE.TO SDE.TO GOOS.TO
    BHC.TO DOO.TO AC.TO TFPM.TO SII.TO AYA.TO FVI.TO PAAS.TO XIU.TO
    SPY QQQ TSLA NVDA AMD PLTR SOFI AAPL AMZN META MSFT GOOGL NFLX COIN MSTR
    HOOD MARA RIOT SMCI ARM AVGO MU INTC F NIO RIVN LCID GME AMC SNAP UBER
    SHOP BABA BAC CCL AAL DKNG RBLX AFRM UPST IONQ RKLB SOUN CVNA
  )

# Option chain snapshots from Questrade via Rust: near-the-money contracts
# for the next weeks on a few liquid underlyings, quoted nightly with the
# exchange greeks. Tickers are Questrade's (US names bare, Canadian names
# with .TO); the names should be ones the owner would accept being assigned.
config :opus, Opus.MarketData.OptionsChainWorker,
  enabled: true,
  underlyings: ~w(SPY QQQ IWM AAPL MSFT NVDA AMZN GOOGL),
  max_days_to_expiry: 45,
  strike_band_pct: 0.10

# US equity daily bars from Massive via Rust. Lists mirror
# auro_research/data/yahoo/universes.py (SP100 + US_ETF); Massive tickers use
# "." for share classes (BRK.B). US intraday stays with the Questrade worker.
config :opus, Opus.MarketData.MassiveBarsWorker,
  days: 7,
  granularities: ["D"],
  watchlist: ~w(
    SPY QQQ IWM DIA EFA EEM TLT IEF GLD SLV USO XLE XLF XLK XLV XLY XLP XLI XLU
    XLB XLRE XME SMH KRE GDX EWJ EWG EWU EWC EWA FXI
    AAPL MSFT NVDA AMZN GOOGL META BRK.B AVGO TSLA LLY JPM V UNH XOM MA JNJ PG HD
    COST ABBV MRK WMT NFLX BAC CVX KO PEP ADBE CRM ORCL AMD TMO LIN MCD ACN CSCO
    ABT WFC DIS INTC IBM QCOM TXN DHR PM VZ AMGN NEE CAT GE INTU UNP HON LOW SPGI
    RTX AXP BKNG ISRG GS NKE MS T BLK PFE SBUX MDT C CVS DE ELV GILD MDLZ ADP AMT
    LMT BMY MO SCHW CI SO DUK CL TGT USB MMM COP BA UPS PYPL KHC GM F MET AIG EMR
    FDX CHTR COF BNY SPG GD
  )

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
