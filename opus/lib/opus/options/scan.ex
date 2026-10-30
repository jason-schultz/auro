defmodule Opus.Options.Scan do
  @moduledoc """
  The daily look through the stored option chains for contracts worth a
  glance. Two lists:

    * **dip_buy** — on an index ETF whose daily RSI(2) closed under 10 while
      above its 100-day average (the one daily edge that survived the
      lockbox), the calls 30–60 days out: the cheap way to express the
      bounce. Only when the latest daily bar is the previous session's (a
      setup on an older close is stale and skipped), and only calls with a
      delta between 0.30 and 0.70, a spread within 10% of the mid
      (`Opus.Options.Paper.Pick.fillable?/1`) and some open interest.
    * **cheap_vol** — for every underlying with a chain, the at-the-money
      call and put nearest 45 days out whose implied volatility is below
      the underlying's 20-day realized (IV/RV under 1.0): the market is
      pricing less movement than the stock has been delivering.

  Only underlyings whose latest chain snapshot is from the scan's New York
  date are scanned. A rerun replaces the day's ideas in one transaction,
  keeping each idea's status (dismissed, taken) by list and contract; an
  underlying that errors keeps the rows it had, and the run reports the
  error so the job retries and the dashboard says so.

  Indicator math and option math stay in Rust (`/api/indicators`,
  `/api/options/scenarios`); this module only selects, ranks and records.
  """

  require Logger

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.{Clock, MarketCalendar, Options}
  alias Opus.Options.Idea
  alias Opus.Options.Paper.Pick
  alias Opus.Repo

  @dte_min 30
  @dte_max 60
  @target_dte 45
  @rsi_oversold 10.0
  @rv_period 20
  @lottery_delta 0.15
  @dip_delta_min 0.30
  @dip_delta_max 0.70
  @ideas_per_setup 8

  @doc """
  Scan every underlying with a chain from `scanned_on` and record the day's
  ideas, replacing those already recorded for `scanned_on` except an
  errored underlying's. `{:ok, count stored}`, or `{:error, words}` naming
  the underlyings that errored (the rest are still recorded).
  """
  @spec run(Date.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run(scanned_on \\ Clock.today()) do
    results =
      for underlying <- Options.underlyings(), current_chain?(underlying, scanned_on) do
        {underlying, scan_underlying(underlying, scanned_on)}
      end

    {scanned, failed} = Enum.split_with(results, &match?({_u, {:ok, _ideas}}, &1))
    ideas = Enum.flat_map(scanned, fn {_u, {:ok, ideas}} -> ideas end)
    kept_ids = Enum.map(failed, fn {u, _error} -> u.instrument_id end)

    {:ok, count} = Repo.transaction(fn -> replace(scanned_on, ideas, kept_ids) end)
    Options.broadcast_ideas(scanned_on)

    case failed do
      [] ->
        {:ok, count}

      failed ->
        {:error,
         "No new ideas for " <>
           Enum.map_join(failed, "; ", fn {u, {:error, why}} -> "#{u.symbol} (#{why})" end) <>
           ". Their earlier ideas from today, if any, are kept."}
    end
  end

  # The day's rows for every underlying but the errored ones go, the new
  # ones come in carrying the status the user gave the same list and
  # contract earlier today.
  defp replace(scanned_on, ideas, kept_ids) do
    replaced =
      from(i in Idea,
        where:
          i.scanned_on == ^scanned_on and
            i.underlying_instrument_id not in type(^kept_ids, {:array, :integer})
      )

    statuses =
      replaced
      |> select([i], {{i.list, i.contract_id}, i.status})
      |> Repo.all()
      |> Map.new()

    Repo.delete_all(replaced)

    ideas
    |> Enum.map(&%{&1 | status: Map.get(statuses, {&1.list, &1.contract_id}, &1.status)})
    |> Enum.chunk_every(200)
    |> Enum.each(&Repo.insert_all(Idea, &1))

    length(ideas)
  end

  # A chain captured on an earlier New York date would rank yesterday's (or
  # last week's) quotes as today's ideas.
  defp current_chain?(%{symbol: symbol, captured_at: captured_at}, scanned_on) do
    current = Clock.date(captured_at) == scanned_on

    if not current,
      do:
        Logger.warning(
          "[OptionsScan] #{symbol}: latest chain is from #{Clock.date(captured_at)}, " <>
            "not #{scanned_on}; skipped"
        )

    current
  end

  defp scan_underlying(%{symbol: symbol} = underlying, scanned_on) do
    case Client.get_indicators(symbol, "D",
           ma_period: 100,
           rsi_period: 2,
           rv_period: @rv_period
         ) do
      {:ok, %{"indicators" => indicators} = response} ->
        close_on = close_date(response["last_close_time"])

        if dip_buy_setup?(underlying, indicators) and not fresh_close?(close_on, scanned_on),
          do:
            Logger.warning(
              "[OptionsScan] #{symbol}: dip-buy setup on the #{inspect(close_on)} close, " <>
                "not the previous session's; no dip-buy ideas"
            )

        candidates = Options.candidates(symbol, @dte_min, @dte_max)
        ideas_for(underlying, indicators, close_on, candidates, scanned_on, &scenario/1)

      {:error, reason} ->
        Logger.warning("[OptionsScan] #{symbol}: no indicators (#{inspect(reason)})")
        {:error, "no daily indicators: #{Client.describe_error(reason)}"}
    end
  end

  # Daily bars are stamped at New York midnight of their session.
  defp close_date(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, at, _offset} -> Clock.date(at)
      _ -> nil
    end
  end

  defp close_date(_time), do: nil

  @doc "Whether a daily close on `close_on` is the last session before `scanned_on`."
  @spec fresh_close?(Date.t() | nil, Date.t()) :: boolean()
  def fresh_close?(%Date{} = close_on, scanned_on),
    do: close_on == MarketCalendar.previous_trading_day(scanned_on)

  def fresh_close?(_close_on, _scanned_on), do: false

  @doc """
  The ideas one underlying yields from its daily indicator scalars, the
  date of the daily close they were computed on, and its candidate
  contracts (every strike of either kind, 30–60 days out, from the latest
  snapshot). `scenario_fn` turns a candidate into the model numbers
  (`breakeven`, `expected_move`, `probability_profit`), `nil` when the
  engine declines the contract, or `{:error, reason}` when it can't be
  asked. Pure apart from that function, so the rules are testable without
  the engine. `{:ok, ideas}`, or `{:error, words}` on the first engine error.
  """
  @spec ideas_for(
          map(),
          map(),
          Date.t() | nil,
          [map()],
          Date.t(),
          (map() -> map() | nil | {:error, term()})
        ) :: {:ok, [map()]} | {:error, String.t()}
  def ideas_for(underlying, indicators, close_on, candidates, scanned_on, scenario_fn) do
    rv = indicators["realized_vol_pct"]
    build = &idea(&1, underlying, &2, rv, scanned_on, scenario_fn)

    dip_buy =
      if dip_buy_setup?(underlying, indicators) and fresh_close?(close_on, scanned_on),
        do: Enum.filter(candidates, &dip_buy_contract?/1),
        else: []

    cheap_vol = candidates |> at_the_money_pair() |> Enum.filter(&cheap_vol?(&1, rv))

    with {:ok, dip_buy} <- models(dip_buy, &build.(&1, "dip_buy")),
         {:ok, cheap_vol} <- models(cheap_vol, &build.(&1, "cheap_vol")) do
      dip_buy =
        dip_buy
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(@ideas_per_setup)
        |> Enum.map(&Map.put(&1, :setup, dip_buy_setup_text(indicators, close_on)))

      cheap_vol = Enum.map(cheap_vol, &Map.put(&1, :setup, cheap_vol_text(&1, close_on)))

      {:ok, dip_buy ++ cheap_vol}
    end
  end

  # Each candidate's idea, dropping the ones the engine declined; stops at
  # the first engine error.
  defp models(candidates, build) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case build.(candidate) do
        nil -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, "option model: #{Client.describe_error(reason)}"}}
        idea -> {:cont, {:ok, acc ++ [idea]}}
      end
    end)
  end

  @doc "RSI(2) under 10 above the 100-day average, on an index ETF."
  @spec dip_buy_setup?(map(), map()) :: boolean()
  def dip_buy_setup?(%{asset_class: "etf"}, %{"rsi" => rsi, "ma_deviation_pct" => dev})
      when is_number(rsi) and is_number(dev),
      do: rsi < @rsi_oversold and dev > 0

  def dip_buy_setup?(_underlying, _indicators), do: false

  # A call a dip-buyer could actually trade: neither a lottery ticket nor
  # deep in the money, a fillable quote, and someone holding the contract
  # (when the quote says).
  defp dip_buy_contract?(%{kind: "call", delta: delta} = candidate) when is_number(delta) do
    delta >= @dip_delta_min and delta <= @dip_delta_max and Pick.fillable?(candidate) and
      (is_nil(candidate.open_interest) or candidate.open_interest > 0)
  end

  defp dip_buy_contract?(_candidate), do: false

  # Implied below realized, both known; an implied of zero or less is no
  # reading at all.
  defp cheap_vol?(%{volatility: iv} = candidate, rv)
       when is_number(iv) and iv > 0 and is_number(rv) and rv > 0,
       do: tradeable?(candidate) and iv < rv

  defp cheap_vol?(_candidate, _rv), do: false

  defp dip_buy_setup_text(%{"rsi" => rsi, "ma_deviation_pct" => dev}, close_on) do
    "RSI(2) #{Float.round(rsi * 1.0, 1)} on the #{day(close_on)} close, under " <>
      "#{trunc(@rsi_oversold)}; #{Float.round(dev * 1.0, 1)}% above the 100-day average"
  end

  defp cheap_vol_text(%{iv_pct: iv, rv_pct: rv}, close_on) do
    "implied #{Float.round(iv, 1)}% vs realized #{Float.round(rv, 1)}% " <>
      "(#{@rv_period} sessions to the #{day(close_on)} close)"
  end

  defp day(nil), do: "unknown"
  defp day(date), do: Calendar.strftime(date, "%b %-d")

  # The at-the-money call and put at the expiry nearest 45 days out.
  defp at_the_money_pair([]), do: []

  defp at_the_money_pair(candidates) do
    expiry = candidates |> Enum.map(& &1.dte) |> Enum.min_by(&abs(&1 - @target_dte))

    for kind <- ["call", "put"],
        rows = Enum.filter(candidates, &(&1.dte == expiry and &1.kind == kind)),
        rows != [] do
      Enum.min_by(rows, &abs(&1.strike - &1.spot))
    end
  end

  defp tradeable?(%{bid: bid, ask: ask}),
    do: is_number(bid) and is_number(ask) and bid > 0 and ask > 0

  defp idea(candidate, underlying, list, rv, scanned_on, scenario_fn) do
    case scenario_fn.(candidate) do
      nil ->
        nil

      {:error, _reason} = error ->
        error

      model ->
        spot = candidate.spot
        breakeven = model["breakeven"]
        expected = model["expected_move"]
        breakeven_move = breakeven && abs(breakeven - spot) / spot
        expected_move = expected && expected / spot

        iv =
          if is_number(candidate.volatility) and candidate.volatility > 0,
            do: candidate.volatility

        now = DateTime.utc_now()

        %{
          scanned_on: scanned_on,
          list: list,
          underlying_instrument_id: underlying.instrument_id,
          contract_id: candidate.contract_id,
          kind: candidate.kind,
          strike: candidate.strike,
          expiration: candidate.expiration,
          dte: candidate.dte,
          spot: spot,
          bid: candidate.bid,
          ask: candidate.ask,
          delta: candidate.delta,
          open_interest: candidate.open_interest,
          spread_pct: spread_pct(candidate),
          iv_pct: iv,
          rv_pct: rv,
          iv_rv: iv && rv && rv > 0 && iv / rv,
          breakeven: breakeven,
          breakeven_move_pct: breakeven_move,
          expected_move_pct: expected_move,
          probability_profit: model["probability_profit"],
          lottery: is_number(candidate.delta) and abs(candidate.delta) < @lottery_delta,
          setup: "",
          score: score(list, model, breakeven_move, expected_move, iv, rv),
          status: "new",
          inserted_at: now,
          updated_at: now
        }
        |> Map.update!(:iv_rv, &if(&1 in [nil, false], do: nil, else: &1))
    end
  end

  # dip_buy ranks by how much of the move the market expects is needed to
  # break even, then by the model's chance of profit; cheap_vol by how far
  # implied sits under realized.
  defp score("dip_buy", model, breakeven_move, expected_move, _iv, _rv)
       when is_number(breakeven_move) and is_number(expected_move) and breakeven_move > 0 do
    expected_move / breakeven_move + (model["probability_profit"] || 0.0)
  end

  defp score("cheap_vol", _model, _b, _e, iv, rv) when is_number(iv) and is_number(rv) and iv > 0,
    do: rv / iv

  defp score(_list, _model, _b, _e, _iv, _rv), do: 0.0

  defp spread_pct(%{bid: bid, ask: ask}) when is_number(bid) and is_number(ask) and ask > 0 do
    mid = (bid + ask) / 2
    if mid > 0, do: (ask - bid) / mid, else: nil
  end

  defp spread_pct(_), do: nil

  # The engine's numbers for buying this contract at the ask.
  defp scenario(candidate) do
    request = %{
      underlying: candidate.symbol,
      kind: candidate.kind,
      side: "buy",
      strike: candidate.strike,
      premium: candidate.ask,
      expiration: Date.to_iso8601(candidate.expiration),
      contracts: 1.0,
      spot: candidate.spot
    }

    request =
      if is_number(candidate.volatility) and candidate.volatility > 0,
        do: Map.put(request, :sigma, candidate.volatility / 100),
        else: request

    # The engine turning a contract down (a 4xx) drops that contract; not
    # reaching it is an error for the whole underlying.
    case Client.option_scenarios(request) do
      {:ok, analysis} -> analysis
      {:error, {:http_error, status, _body}} when status in 400..499 -> nil
      {:error, reason} -> {:error, reason}
    end
  end
end
