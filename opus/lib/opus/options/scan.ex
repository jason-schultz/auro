defmodule Opus.Options.Scan do
  @moduledoc """
  The daily look through the stored option chains for contracts worth a
  glance. Two lists:

    * **dip_buy** — on an index ETF whose daily RSI(2) closed under 10 while
      above its 100-day average (the one daily edge that survived the
      lockbox), the calls 30–60 days out: the cheap way to express the
      bounce. Every strike is listed; deltas under 0.15 are marked as the
      lottery tickets they are rather than hidden.
    * **cheap_vol** — for every underlying with a chain, the at-the-money
      call and put nearest 45 days out, with the quote's implied volatility
      against the underlying's 20-day realized. Below 1.0 the market is
      pricing less movement than the stock has been delivering.

  Indicator math and option math stay in Rust (`/api/indicators`,
  `/api/options/scenarios`); this module only selects, ranks and records.
  """

  require Logger

  import Ecto.Query

  alias Opus.Auro.Client
  alias Opus.Options
  alias Opus.Options.Idea
  alias Opus.Repo

  @dte_min 30
  @dte_max 60
  @target_dte 45
  @rsi_oversold 10.0
  @lottery_delta 0.15
  @ideas_per_setup 8

  @doc """
  Scan every underlying with a stored chain and record the day's ideas,
  replacing any already recorded for `scanned_on`. Returns the count stored.
  """
  @spec run(Date.t()) :: {:ok, non_neg_integer()}
  def run(scanned_on \\ Opus.Clock.today()) do
    ideas =
      Options.underlyings()
      |> Enum.flat_map(&scan_underlying(&1, scanned_on))

    Repo.delete_all(from(i in Idea, where: i.scanned_on == ^scanned_on))

    ideas
    |> Enum.chunk_every(200)
    |> Enum.each(&Repo.insert_all(Idea, &1))

    {:ok, length(ideas)}
  end

  defp scan_underlying(%{symbol: symbol} = underlying, scanned_on) do
    case Client.get_indicators(symbol, "D", ma_period: 100, rsi_period: 2, rv_period: 20) do
      {:ok, %{"indicators" => indicators}} ->
        candidates = Options.candidates(symbol, @dte_min, @dte_max)
        ideas_for(underlying, indicators, candidates, scanned_on, &scenario/1)

      {:error, reason} ->
        Logger.warning("[OptionsScan] #{symbol}: no indicators (#{inspect(reason)}); skipped")
        []
    end
  end

  @doc """
  The ideas one underlying yields from its daily indicator scalars and its
  candidate contracts (every strike of either kind, 30–60 days out, from the
  latest snapshot). `scenario_fn` turns a candidate into the model numbers
  (`breakeven`, `expected_move`, `probability_profit`) or `nil`. Pure apart
  from that function, so the rules are testable without the engine.
  """
  @spec ideas_for(map(), map(), [map()], Date.t(), (map() -> map() | nil)) :: [map()]
  def ideas_for(underlying, indicators, candidates, scanned_on, scenario_fn) do
    rv = indicators["realized_vol_pct"]

    dip_buy =
      if dip_buy_setup?(underlying, indicators) do
        candidates
        |> Enum.filter(&(&1.kind == "call" and tradeable?(&1)))
        |> Enum.map(&idea(&1, underlying, "dip_buy", rv, scanned_on, scenario_fn))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(@ideas_per_setup)
        |> Enum.map(&Map.put(&1, :setup, dip_buy_setup_text(indicators)))
      else
        []
      end

    cheap_vol =
      case at_the_money_pair(candidates) do
        [] ->
          []

        pair ->
          pair
          |> Enum.filter(&tradeable?/1)
          |> Enum.map(&idea(&1, underlying, "cheap_vol", rv, scanned_on, scenario_fn))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Map.put(&1, :setup, cheap_vol_text(&1)))
      end

    dip_buy ++ cheap_vol
  end

  @doc "RSI(2) under 10 above the 100-day average, on an index ETF."
  @spec dip_buy_setup?(map(), map()) :: boolean()
  def dip_buy_setup?(%{asset_class: "etf"}, %{"rsi" => rsi, "ma_deviation_pct" => dev})
      when is_number(rsi) and is_number(dev),
      do: rsi < @rsi_oversold and dev > 0

  def dip_buy_setup?(_underlying, _indicators), do: false

  defp dip_buy_setup_text(%{"rsi" => rsi, "ma_deviation_pct" => dev}) do
    "RSI(2) #{Float.round(rsi * 1.0, 1)} under #{trunc(@rsi_oversold)}, " <>
      "#{Float.round(dev * 1.0, 1)}% above the 100-day average"
  end

  defp cheap_vol_text(%{iv_pct: iv, rv_pct: rv}) when is_number(iv) and is_number(rv) do
    "implied #{Float.round(iv, 1)}% vs realized #{Float.round(rv, 1)}%"
  end

  defp cheap_vol_text(%{iv_pct: iv}) when is_number(iv),
    do: "implied #{Float.round(iv, 1)}%, realized unknown"

  defp cheap_vol_text(_), do: "no volatility on the quote"

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

      model ->
        spot = candidate.spot
        breakeven = model["breakeven"]
        expected = model["expected_move"]
        breakeven_move = breakeven && abs(breakeven - spot) / spot
        expected_move = expected && expected / spot
        iv = candidate.volatility
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

    case Client.option_scenarios(request) do
      {:ok, analysis} -> analysis
      {:error, _} -> nil
    end
  end
end
