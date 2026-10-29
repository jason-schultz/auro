defmodule Opus.Auro.Client do
  @moduledoc """
  HTTP client for the Auro Rust engine.
  """
  require Logger

  import Opus.Trading.Granularity, only: [is_valid: 1]

  @default_base_url "http://localhost:3000"

  def base_url, do: Application.get_env(:opus, :auro_base_url, @default_base_url)

  @doc """
  One sentence a page can show for a failed call: the engine's own message
  when it sent one, otherwise its status, otherwise that it is unreachable.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:http_error, _status, %{"error" => message}}) when is_binary(message),
    do: message

  def describe_error({:http_error, status, _body}), do: "Auro answered with status #{status}."
  def describe_error(%{reason: :econnrefused}), do: "Auro is not running."
  def describe_error(_), do: "Could not reach Auro."

  @doc """
  Remove a trade from Rust's in-memory open_positions map.

  Called by the reconciler after detecting an OANDA-side close, to keep
  Rust's in-memory state in sync. Idempotent on the Rust side — removing
  an absent key is a no-op success.
  """
  @spec delete_position(String.t() | integer()) :: {:ok, map()} | {:error, any()}
  def delete_position(trade_id) do
    Logger.info("[AuroClient] Deleting position for trade #{trade_id} from Auro")

    client()
    |> Req.delete(url: "/api/positions/#{trade_id}")
    |> handle_response()
  end

  @doc """
  Push the full rules payload to Rust. Replaces the in-memory rules cache
  atomically. Per Decision #23, this is the activation channel; the DB
  write is the persistence channel.

  Payload shape:
      %{
        rules: %{"strategy-uuid" => %{enabled: true, reason: "..."}, ...},
        computed_at: ~U[2026-05-06 ...]
      }
  """
  @spec push_rules(map()) :: {:ok, map()} | {:error, any()}
  def push_rules(payload) do
    Logger.info("[AuroClient] Pushing rules payload with #{map_size(payload.rules)} strategies")
    client() |> Req.post(url: "/api/rules", json: payload) |> handle_response()
  end

  @doc "Fetch live engine subsystem freshness from Rust health endpoint."
  @spec get_live_health() :: {:ok, map()} | {:error, any()}
  def get_live_health do
    # A page read (the dashboard): when the engine is down, say so at once
    # rather than after the retry budget.
    client()
    |> Req.get(url: "/api/health/live", retry: false)
    |> handle_response()
  end

  @doc """
  Fetch indicator scalars (ADX, ATR%, MA deviation, Bollinger Bands) for an
  (instrument, granularity) pair from Rust's in-memory candle buffer.

  Periods default to standard values (ADX 14, Bollinger 20/2.0, ATR 14, MA 20)
  unless overridden via `opts`.
  """
  @spec get_indicators(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_indicators(instrument, granularity, opts \\ [])

  def get_indicators(instrument, granularity, opts)
      when is_valid(granularity) do
    params =
      opts
      |> Keyword.take([
        :adx_period,
        :bollinger_period,
        :bollinger_std,
        :atr_period,
        :ma_period,
        :roc_period,
        :rsi_period,
        :rv_period
      ])
      |> Enum.into(%{})

    client()
    |> Req.get(url: "/api/indicators/#{instrument}/#{granularity}", params: params)
    |> handle_response()
  end

  def get_indicators(_instrument, granularity, _opts),
    do: {:error, {:invalid_granularity, granularity}}

  @doc """
  Create a live strategy (disabled) through Rust, which validates the config
  and loads candle buffers for the instrument. Returns `{:error,
  {:http_error, 409, body}}` when the strategy already exists.
  """
  @spec create_live_strategy(map()) :: {:ok, map()} | {:error, any()}
  def create_live_strategy(attrs) do
    client()
    |> Req.post(url: "/api/live/strategies", json: attrs)
    |> handle_response()
  end

  @doc """
  Submit a strategy config to the pipeline backtest stage.
  Rust loads the config, runs the backtest, evaluates thresholds, and writes
  the result to strategy_evaluations.

  Returns `{:ok, %{status: "passed"|"failed", stats: map, failure_reason: string|nil}}`.
  """
  @spec run_pipeline_backtest(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_backtest(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline backtest for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/backtest",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc """
  Run the walk-forward validation stage for a strategy config.
  Rust splits candles 70/30 IS/OOS, runs both, evaluates thresholds, writes result.
  """
  @spec run_pipeline_walk_forward(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_walk_forward(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline walk_forward for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/walk_forward",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc """
  Run the Monte Carlo validation stage for a strategy config.
  Rust runs the strategy once to get trades, then shuffles the PnL sequence
  10,000 times and computes: profitable_pct, median_sharpe, p95_drawdown.
  """
  @spec run_pipeline_monte_carlo(String.t()) :: {:ok, map()} | {:error, any()}
  def run_pipeline_monte_carlo(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline monte_carlo for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/monte_carlo",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc "Run the sealed-holdout stage (POST /api/pipeline/holdout)."
  @spec run_pipeline_holdout(String.t()) :: {:ok, map()} | {:error, term()}
  def run_pipeline_holdout(config_id) when is_binary(config_id) do
    Logger.info("[AuroClient] Running pipeline holdout for config #{config_id}")

    client()
    |> Req.post(
      url: "/api/pipeline/holdout",
      json: %{strategy_config_id: config_id},
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  @doc """
  Replace a live strategy's config through Rust, which re-validates it. The
  evaluator reads strategies from the DB each cycle, so changes apply on the
  next bar.
  """
  @spec update_live_strategy(String.t(), map()) :: {:ok, map()} | {:error, any()}
  def update_live_strategy(id, attrs) when is_binary(id) do
    client()
    |> Req.put(url: "/api/live/strategies/#{id}", json: attrs)
    |> handle_response()
  end

  @doc """
  Every live strategy with the statistics Rust aggregates for it: backtest,
  out-of-sample, k-fold and live. `%{"strategies" => [...], "count" => n}`.
  """
  @spec list_live_strategies() :: {:ok, map()} | {:error, any()}
  def list_live_strategies do
    # A page read: when the engine is down the page says so at once rather
    # than after the retry budget.
    client() |> Req.get(url: "/api/live/strategies", retry: false) |> handle_response()
  end

  @doc """
  Flip a live strategy's enabled switch. Rust owns the switch because it
  loads or unloads the instrument's candle buffers as a side effect.
  Returns `%{"id" => id, "enabled" => bool}` (and the pin flag it records).
  """
  @spec toggle_live_strategy(String.t()) :: {:ok, map()} | {:error, any()}
  def toggle_live_strategy(id) when is_binary(id) do
    client() |> Req.post(url: "/api/live/strategies/#{id}/toggle", json: %{}) |> handle_response()
  end

  @doc """
  Delete a live strategy. Rust refuses with 400 while the strategy has
  open trades, and unloads the instrument's buffers if nothing else needs them.
  """
  @spec delete_live_strategy(String.t()) :: {:ok, map()} | {:error, any()}
  def delete_live_strategy(id) when is_binary(id) do
    client() |> Req.delete(url: "/api/live/strategies/#{id}") |> handle_response()
  end

  @doc """
  Have Rust fetch a symbol's Questrade bars for the last `days` calendar days
  and upsert the completed ones into `candles`. Idempotent — overlapping
  re-fetches overwrite identical rows. `granularity` is ours ("M1", "M5").
  """
  @spec persist_questrade_candles(String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, any()}
  def persist_questrade_candles(symbol, granularity, days)
      when is_binary(symbol) and is_binary(granularity) and is_integer(days) do
    client()
    |> Req.post(
      url: "/api/questrade/candles/persist",
      json: %{symbol: symbol, granularity: granularity, days: days},
      receive_timeout: 300_000
    )
    |> handle_response()
  end

  @doc """
  Have Rust fetch the last `days` days of a US symbol's bars from Massive and
  upsert the completed ones into `candles`. Same contract as the Questrade
  persist call; `granularity` is ours ("D"). Rust paces the vendor calls, so
  a two-year backfill can take a minute per symbol.
  """
  @spec persist_massive_candles(String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, any()}
  def persist_massive_candles(symbol, granularity, days)
      when is_binary(symbol) and is_binary(granularity) and is_integer(days) do
    client()
    |> Req.post(
      url: "/api/massive/candles/persist",
      json: %{symbol: symbol, granularity: granularity, days: days},
      receive_timeout: 300_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  Have Rust capture tonight's chain on `underlying` from Questrade
  (POST /api/questrade/options/snapshot): the near-the-money contracts into
  `option_contracts` and their quotes with the exchange greeks into
  `option_quotes`. One chain call plus one quotes call per hundred
  contracts, inside Questrade's rate limit.
  """
  @spec snapshot_option_chain(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def snapshot_option_chain(underlying, opts \\ []) when is_binary(underlying) do
    client()
    |> Req.post(
      url: "/api/questrade/options/snapshot",
      json: option_body(underlying, opts),
      receive_timeout: 300_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  Run a strategy's rules over the last `count` bars of its instrument
  (POST /api/strategy/signal-preview), the same runner the backtest uses.
  `parameters` is the full strategy JSON. The body has `"signals"` (entries
  and exits with price and why each exit happened) and `"bars"` (each bar's
  OHLC and every rule's true/false on it). Validates the rules too: a
  strategy the engine can't read answers 400 with the reason.
  """
  @spec signal_preview(map(), pos_integer()) :: {:ok, map()} | {:error, any()}
  def signal_preview(parameters, count) when is_map(parameters) do
    client()
    |> Req.post(
      url: "/api/strategy/signal-preview",
      json: %{parameters: parameters, count: count},
      receive_timeout: 30_000,
      retry: false
    )
    |> handle_response(:quiet)
  end

  @doc """
  A strategy's running return against just holding its instrument, and its
  drawdown, over the same history the pipeline backtests
  (POST /api/strategy/report). `parameters` is the full strategy JSON.
  Answers `%{"report" => %{"points" => [...], "summary" => %{...}}}`.
  """
  @spec strategy_report(map()) :: {:ok, map()} | {:error, any()}
  def strategy_report(parameters) when is_map(parameters) do
    client()
    |> Req.post(
      url: "/api/strategy/report",
      json: %{parameters: parameters},
      receive_timeout: 60_000,
      retry: false
    )
    |> handle_response(:quiet)
  end

  @doc """
  Every trade a strategy's backtest made over the history the pipeline
  backtests (POST /api/strategy/trades). Answers
  `%{"from", "to", "trades" => [%{"entry_time", "exit_time", "pnl_percent"}]}`.
  """
  @spec backtest_trades(map()) :: {:ok, map()} | {:error, any()}
  def backtest_trades(parameters) when is_map(parameters) do
    client()
    |> Req.post(
      url: "/api/strategy/trades",
      json: %{parameters: parameters},
      receive_timeout: 60_000,
      retry: false
    )
    |> handle_response(:quiet)
  end

  @doc """
  Strategies backtested together on one account, with the account limits
  (`limits`, or nil for none) applied as live (POST /api/strategy/portfolio).
  `plays` are `%{key, parameters, breaker_exempt}`. With `base` (a play's
  key) it answers each other play paired with that one instead. Slow: every
  play is backtested, so a long list of 5-minute strategies takes a minute.
  """
  @spec portfolio([map()], map() | nil, String.t() | nil) :: {:ok, map()} | {:error, any()}
  def portfolio(plays, limits, base \\ nil) when is_list(plays) do
    client()
    |> Req.post(
      url: "/api/strategy/portfolio",
      json: %{plays: plays, limits: limits, base: base},
      receive_timeout: 300_000,
      retry: false
    )
    |> handle_response(:quiet)
  end

  @doc """
  The strategy re-run at a grid of nearby settings, each judged by the
  backtest standard (POST /api/strategy/sensitivity). `x` and `y` are
  `%{component, param, values}`; `y` may be nil for a single row. Answers
  `%{"cells" => [%{"x", "y", "total_return", "num_trades", "t_stat", "passed"}]}`.
  Slow on intraday history (about 40 s for 25 cells on 5-minute bars).
  """
  @spec strategy_sensitivity(map(), map(), map() | nil) :: {:ok, map()} | {:error, any()}
  def strategy_sensitivity(parameters, x, y) when is_map(parameters) and is_map(x) do
    client()
    |> Req.post(
      url: "/api/strategy/sensitivity",
      json: %{parameters: parameters, x: x, y: y},
      receive_timeout: 180_000,
      retry: false
    )
    |> handle_response(:quiet)
  end

  @doc """
  Have Rust quote only these stored contracts on `underlying` from Questrade
  (POST /api/questrade/options/quotes) and store the quotes in
  `option_quotes`: the paper books' open legs, during the session. Contracts
  Questrade no longer lists come back in `"missing"`.
  """
  @spec quote_option_contracts(String.t(), [integer()]) :: {:ok, map()} | {:error, any()}
  def quote_option_contracts(underlying, contract_ids)
      when is_binary(underlying) and is_list(contract_ids) do
    client()
    |> Req.post(
      url: "/api/questrade/options/quotes",
      json: %{underlying: underlying, contract_ids: contract_ids},
      receive_timeout: 60_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  Massive history path. Have Rust list the option contracts on `underlying` expiring within
  `max_days_to_expiry` days and striking within `strike_band_pct` of the
  last close, and upsert them into `option_contracts`. Needs the
  underlying's daily bars stored first (that is where the spot comes from).
  """
  @spec sync_option_contracts(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def sync_option_contracts(underlying, opts \\ []) when is_binary(underlying) do
    client()
    |> Req.post(
      url: "/api/massive/options/contracts/sync",
      json: option_body(underlying, opts),
      receive_timeout: 300_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  Massive history path. Have Rust fetch the last `days` days of daily bars for every stored
  contract on `underlying` that is live and near the money, and upsert the
  completed ones into `option_bars`. One vendor call per contract: on the
  free plan budget about twelve seconds each.
  """
  @spec persist_option_bars(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def persist_option_bars(underlying, days, opts \\ [])
      when is_binary(underlying) and is_integer(days) do
    client()
    |> Req.post(
      url: "/api/massive/options/bars/persist",
      json: Map.put(option_body(underlying, opts), :days, days),
      receive_timeout: 3_600_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  What one single-leg option position does at expiry
  (POST /api/options/scenarios): breakeven, yield, assignment odds and a
  price-by-price outcome table. Pure math in Rust; spot and rate are filled
  from storage when left out. Interactive, so no retries.
  """
  @spec option_scenarios(map()) :: {:ok, map()} | {:error, any()}
  def option_scenarios(params) when is_map(params) do
    client()
    |> Req.post(
      url: "/api/options/scenarios",
      json: params,
      receive_timeout: 15_000,
      retry: false
    )
    |> handle_response()
  end

  @doc """
  Have Rust ask Questrade who each listing in the instruments table is
  (POST /api/instruments/enrich): records the symbol id, exchange and
  currency Questrade reports. One search and one detail call per listing.
  """
  @spec enrich_instruments() :: {:ok, map()} | {:error, any()}
  def enrich_instruments do
    client()
    |> Req.post(url: "/api/instruments/enrich", json: %{}, receive_timeout: 300_000, retry: false)
    |> handle_response()
  end

  defp option_body(underlying, opts) do
    %{underlying: underlying}
    |> maybe_put(:max_days_to_expiry, opts[:max_days_to_expiry])
    |> maybe_put(:strike_band_pct, opts[:strike_band_pct])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Has Rust record today's OANDA financing rates (POST /api/financing/snapshot).
  """
  @spec snapshot_financing() :: {:ok, map()} | {:error, term()}
  def snapshot_financing do
    client()
    |> Req.post(url: "/api/financing/snapshot", receive_timeout: 60_000)
    |> handle_response()
  end

  # The three account-page reads are interactive (a person is waiting on
  # them), so they fail fast instead of taking Req's default retries.

  @doc "Connection status and balances for every broker (OANDA, Questrade, Wealthsimple)."
  @spec list_brokers() :: {:ok, [map()]} | {:error, term()}
  def list_brokers do
    client()
    |> Req.get(url: "/api/brokers", retry: false)
    |> handle_response()
  end

  @doc "Wealthsimple accounts with their hand-entered positions."
  @spec wealthsimple_accounts() :: {:ok, [map()]} | {:error, term()}
  def wealthsimple_accounts do
    client()
    |> Req.get(url: "/api/brokers/wealthsimple", retry: false)
    |> handle_response()
  end

  @doc "Re-price every Wealthsimple position from Questrade quotes."
  @spec refresh_wealthsimple_prices() :: {:ok, map()} | {:error, term()}
  def refresh_wealthsimple_prices do
    client()
    |> Req.post(
      url: "/api/brokers/wealthsimple/refresh-prices",
      receive_timeout: 30_000,
      retry: false
    )
    |> handle_response()
  end

  # -- Private --

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    Logger.info("[AuroClient] Request succeeded: #{inspect(body)}")
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("[AuroClient] Request failed with status #{status}: #{inspect(body)}")
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.error("[AuroClient] Request failed: #{inspect(reason)}")
    {:error, reason}
  end

  # A large body (a chart's bars) isn't worth a log line on success.
  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, :quiet), do: {:ok, body}
  defp handle_response(result, :quiet), do: handle_response(result)

  defp client do
    Req.new(
      base_url: base_url(),
      headers: [{"Content-Type", "application/json"}]
    )
  end
end
