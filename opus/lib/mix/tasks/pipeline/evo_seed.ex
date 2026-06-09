defmodule Mix.Tasks.Pipeline.EvoSeed do
  @shortdoc "Start evolutionary lineages for all instruments × strategies (exploratory mode)"

  @moduledoc """
  Seeds the pipeline with exploratory evo lineages for all instrument/strategy
  combinations. Uses submit_evo_seed_exploratory/1 so the seed itself is not
  backtested — generation-1 children are spawned immediately with mutated params.

  Usage:
    mix pipeline.evo_seed                        # H1, both strategies
    mix pipeline.evo_seed --granularity D
    mix pipeline.evo_seed --granularity H4
    mix pipeline.evo_seed --granularity M15
    mix pipeline.evo_seed --granularity M5
    mix pipeline.evo_seed --strategy mean_reversion         # only MR
    mix pipeline.evo_seed --strategy trend_following        # only TF
    mix pipeline.evo_seed --strategy donchian               # only Donchian
    mix pipeline.evo_seed --strategy rsi2_dipbuy --granularity D
    mix pipeline.evo_seed --strategy mean_reversion --granularity H1
    mix pipeline.evo_seed --clean                # truncate all pipeline data first
    mix pipeline.evo_seed --clean --granularity H1

  --clean truncates strategy_configs, strategy_evaluations, and pending/running
  pipeline Oban jobs before seeding. Does NOT touch live_strategies.

  --strategy restricts the run to a single strategy type. Valid values:
    "mean_reversion", "trend_following", "donchian", "rsi2_dipbuy".
    Omit to seed all configured.

  Skips combos that already have an active evo lineage (evo_generation=0 seed
  with the same instrument/strategy/granularity).
  """

  use Mix.Task

  import Ecto.Query

  alias Opus.Pipeline.{Coordinator, StrategyConfig}
  alias Opus.Repo

  @instruments ~w[
    EUR_USD GBP_USD USD_CAD USD_JPY AUD_USD XAU_USD
    EUR_JPY EUR_GBP EUR_CHF EUR_CAD EUR_AUD GBP_JPY
    GBP_AUD GBP_CAD AUD_JPY AUD_NZD AUD_CAD NZD_USD
    NZD_JPY NZD_CAD CAD_JPY CAD_CHF CHF_JPY
    WTICO_USD BCO_USD NATGAS_USD XCU_USD CORN_USD SOYBN_USD WHEAT_USD SUGAR_USD
    XAG_USD XPT_USD XPD_USD
    SPX500_USD NAS100_USD US30_USD UK100_GBP DE30_EUR JP225_USD AU200_AUD EU50_EUR
  ]

  @rsi2_instruments ~w[
    US30_USD NAS100_USD SPX500_USD DE30_EUR UK100_GBP AU200_AUD JP225_USD EU50_EUR
  ]

  # Seed params per strategy class. TF now seeds documented discrete variants
  # as independent non-evolving lineages. MR remains the same exploratory seed.
  @seed_params %{
    "D" => %{
      "trend_following" => :tf_variants,
      "donchian" => :composite_donchian_v1,
      "rsi2_dipbuy" => :composite_rsi2_dipbuy_v1
    },
    "H1" => %{
      "trend_following" => :tf_variants,
      "donchian" => :composite_donchian_v1,
      "mean_reversion" => :composite_mr_v1,
      "rsi2_dipbuy" => :composite_rsi2_dipbuy_v1
    },
    "H4" => %{
      "trend_following" => :tf_variants,
      "donchian" => :composite_donchian_v1,
      "mean_reversion" => :composite_mr_v1,
      "rsi2_dipbuy" => :composite_rsi2_dipbuy_v1
    },
    "M15" => %{
      "mean_reversion" => :composite_mr_v1
    },
    "M5" => %{
      "mean_reversion" => :composite_mr_v1
    }
  }

  @tf_variants [
    %{
      name: "50_200",
      fast: 50,
      slow: 200,
      ma_type: "sma",
      source: "Britannica/Investopedia golden cross — textbook baseline (SMA)"
    },
    %{
      name: "21_55",
      fast: 21,
      slow: 55,
      ma_type: "ema",
      source:
        "Fibonacci EMA crossover — practitioner convention (QuantifiedStrategies backtest; RoboForex). Exploratory, not academic canon."
    },
    %{
      name: "13_34",
      fast: 13,
      slow: 34,
      ma_type: "ema",
      source:
        "Fibonacci EMA crossover — 34 EMA = Raghee Horner 'Dave wave' (Trading Forex for Maximum Profit); StockCharts 5/8/13 cousin. Exploratory; whipsaw-prone in ranges."
    }
  ]

  # Keep this in sync with Rust `Granularity::buffer_capacity()` so we avoid
  # seeding TF variants that cannot compute on live buffers.
  @buffer_capacity_by_granularity %{
    "M1" => 500,
    "M5" => 500,
    "M15" => 400,
    "H1" => 256,
    "H4" => 256,
    "D" => 256
  }

  # TF stop policy by granularity:
  # - D/H4 use ATR multiple to avoid noise-tight fixed stops on higher timeframes.
  # - H1 (and others) keep the existing fixed-pct stop because H1 is mid-run.
  @tf_fixed_stop %{"type" => "FixedPct", "params" => %{"pct" => -0.02}}
  @tf_atr_stop %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}}

  defp tf_stop_for_granularity(granularity) do
    case granularity do
      "D" -> @tf_atr_stop
      "H4" -> @tf_atr_stop
      _ -> @tf_fixed_stop
    end
  end

  # Build a standalone textbook Donchian breakout strategy (20-in / 10-out).
  # Seeded on H1/H4 only (not D) for sufficient validation trade counts.
  defp build_donchian_composite(instrument, granularity) do
    %{
      "strategy_id" => nil,
      "strategy_name" => "donchian_20_10_#{instrument}_#{granularity}",
      "version" => "v1_composite",
      "instrument" => instrument,
      "granularity" => granularity,
      "components" => %{
        "dc" => %{
          "type" => "Donchian",
          "params" => %{
            "entry_period" => 20,
            "exit_period" => 10
          }
        }
      },
      "entry" => %{
        "long" => "dc.breakout_long",
        "short" => "dc.breakout_short"
      },
      "exit" => %{
        "long" => "dc.exit_long",
        "short" => "dc.exit_short"
      },
      "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}},
      "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
    }
  end

  # Build the composite-shape Strategy JSON for a TF variant.
  # D/H4 use ATR multiple (k=3.0, period=14) as practitioner judgment for
  # trend systems on higher TFs; H1/others keep fixed -2% to preserve
  # existing H1 behavior.
  defp build_tf_composite(instrument, granularity, variant) do
    %{
      "strategy_id" => nil,
      "strategy_name" => "tf_#{variant.name}_#{instrument}_#{granularity}",
      "version" => "v1_composite",
      "instrument" => instrument,
      "granularity" => granularity,
      "source_note" => variant.source,
      "components" => %{
        "tf" => %{
          "type" => "TrendFollowing",
          "params" => %{
            "fast_period" => variant.fast,
            "slow_period" => variant.slow,
            "ma_type" => variant.ma_type
          }
        }
      },
      "entry" => %{
        "long" => "tf.bullish_cross",
        "short" => "tf.bearish_cross"
      },
      "exit" => %{
        "long" => "tf.bearish_cross",
        "short" => "tf.bullish_cross"
      },
      "stop" => tf_stop_for_granularity(granularity),
      "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
    }
  end

  # Build the composite-shape Strategy JSON for MR v1.
  # Textbook Investopedia baseline: Z-score entry + RSI confirmation,
  # return-to-mean exit, Z-extension stop anchored at the MA.
  defp build_mr_v1_composite(instrument, granularity) do
    %{
      "strategy_id" => nil,
      "strategy_name" => "mr_v1_#{instrument}_#{granularity}",
      "version" => "v1_composite",
      "instrument" => instrument,
      "granularity" => granularity,
      "components" => %{
        "mr" => %{
          "type" => "MeanReversion",
          "params" => %{
            "ma_period" => 20,
            "rsi_period" => 14,
            "entry_z_threshold" => 2.0,
            "rsi_oversold" => 30.0,
            "rsi_overbought" => 70.0,
            "stop_z_threshold" => 3.5
          }
        }
      },
      "entry" => %{
        "long" => "mr.long",
        "short" => "mr.short"
      },
      "exit" => %{
        "long" => "mr.exit_long",
        "short" => "mr.exit_short"
      },
      # MR's SL is component-derived (anchored at MA ± k·stdev), not a fixed
      # pct from entry. The "mr" component computes the absolute SL price via
      # its Signaler::stop_price impl.
      "stop" => %{"type" => "FromComponent", "params" => %{"component" => "mr"}},
      "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
    }
  end

  # RSI(2) dip-buy baseline (long-only, daily indices):
  # entry = RSI oversold AND trend MA above; exit = close above short MA OR time stop.
  defp build_rsi2_dipbuy_composite(instrument, granularity) do
    always_false = %{"and" => ["rsi.long", %{"not" => "rsi.long"}]}

    %{
      "strategy_id" => nil,
      "strategy_name" => "rsi2_dipbuy_v1_#{instrument}_#{granularity}",
      "version" => "v1_composite",
      "instrument" => instrument,
      "granularity" => granularity,
      "components" => %{
        "rsi" => %{
          "type" => "RsiReversion",
          "params" => %{
            "rsi_period" => 2,
            "oversold" => 10.0,
            "overbought" => 90.0
          }
        },
        "trend" => %{
          "type" => "MaFilter",
          "params" => %{
            "period" => 100,
            "ma_type" => "sma"
          }
        },
        "exit_ma" => %{
          "type" => "MaFilter",
          "params" => %{
            "period" => 5,
            "ma_type" => "sma"
          }
        }
      },
      "entry" => %{
        "long" => %{"and" => ["rsi.long", "trend.above"]},
        "short" => always_false
      },
      "exit" => %{
        "long" => "exit_ma.above",
        "short" => always_false
      },
      "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 2.5, "period" => 14}},
      "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}},
      "max_hold_bars" => 10
    }
  end

  defp resolve_params(strategy_type, instrument, granularity, seed) do
    case seed do
      :composite_mr_v1 ->
        build_mr_v1_composite(instrument, granularity)

      :composite_donchian_v1 ->
        build_donchian_composite(instrument, granularity)

      :composite_rsi2_dipbuy_v1 ->
        build_rsi2_dipbuy_composite(instrument, granularity)

      params when is_map(params) ->
        params

      other ->
        raise "unsupported seed config for #{strategy_type}: #{inspect(other)}"
    end
  end

  defp variant_tradeable?(granularity, variant) do
    capacity = Map.fetch!(@buffer_capacity_by_granularity, granularity)
    variant.slow + 1 <= capacity
  end

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [clean: :boolean, granularity: :string, strategy: :string]
      )

    granularity = Keyword.get(opts, :granularity, "H1")
    clean? = Keyword.get(opts, :clean, false)
    strategy_filter = Keyword.get(opts, :strategy)

    unless Map.has_key?(@seed_params, granularity) do
      Mix.shell().error(
        "Unknown granularity: #{granularity}. Valid: #{Map.keys(@seed_params) |> Enum.join(", ")}"
      )

      exit(:shutdown)
    end

    params_for_gran = Map.fetch!(@seed_params, granularity)
    all_strategies = Map.keys(params_for_gran)

    strategies =
      case strategy_filter do
        nil ->
          all_strategies

        chosen ->
          unless chosen in all_strategies do
            Mix.shell().error(
              "Unknown strategy: #{chosen}. Valid: #{Enum.join(all_strategies, ", ")}"
            )

            exit(:shutdown)
          end

          [chosen]
      end

    if clean? do
      Mix.shell().info("=== Cleaning pipeline data ===")
      clean_pipeline()
      Mix.shell().info("Done.\n")
    end

    total_combos =
      Enum.reduce(strategies, 0, fn
        "trend_following", acc -> acc + length(@instruments) * length(@tf_variants)
        "donchian", acc -> acc + length(@instruments)
        "rsi2_dipbuy", acc -> acc + length(@rsi2_instruments)
        _strategy, acc -> acc + length(@instruments)
      end)

    Mix.shell().info(
      "Seeding evo lineages: #{length(@instruments)} instruments × #{length(strategies)} strategies " <>
        "(#{granularity}) = #{total_combos} combos\n"
    )

    {submitted, skipped, failed} =
      Enum.reduce(@instruments, {0, 0, 0}, fn instrument, {s, sk, f} ->
        Enum.reduce(strategies, {s, sk, f}, fn strategy_type, {s2, sk2, f2} ->
          case strategy_type do
            "trend_following" ->
              Enum.reduce(@tf_variants, {s2, sk2, f2}, fn variant, {sv, skv, fv} ->
                cond do
                  not variant_tradeable?(granularity, variant) ->
                    capacity = Map.fetch!(@buffer_capacity_by_granularity, granularity)

                    Mix.shell().info(
                      "  [skip] trend_following/#{variant.name} #{instrument} #{granularity} — " <>
                        "slow+1=#{variant.slow + 1} exceeds buffer_capacity=#{capacity}"
                    )

                    {sv, skv + 1, fv}

                  already_seeded?(instrument, strategy_type, granularity, variant.slow) ->
                    Mix.shell().info(
                      "  [skip] trend_following/#{variant.name} #{instrument} #{granularity} — lineage exists"
                    )

                    {sv, skv + 1, fv}

                  true ->
                    parameters = build_tf_composite(instrument, granularity, variant)

                    attrs = %{
                      instrument: instrument,
                      granularity: granularity,
                      strategy_type: strategy_type,
                      parameters: parameters
                    }

                    case Coordinator.submit_evo_seed(attrs) do
                      {:ok, config} ->
                        Mix.shell().info(
                          "  [seed] trend_following/#{variant.name} #{instrument} #{granularity} → #{config.id}"
                        )

                        {sv + 1, skv, fv}

                      {:error, reason} ->
                        Mix.shell().error(
                          "  [FAIL] trend_following/#{variant.name} #{instrument} #{granularity}: #{inspect(reason)}"
                        )

                        {sv, skv, fv + 1}
                    end
                end
              end)

            "donchian" ->
              if already_seeded?(instrument, strategy_type, granularity, nil) do
                Mix.shell().info(
                  "  [skip] #{strategy_type} #{instrument} #{granularity} — lineage exists"
                )

                {s2, sk2 + 1, f2}
              else
                parameters =
                  resolve_params(
                    strategy_type,
                    instrument,
                    granularity,
                    params_for_gran[strategy_type]
                  )

                attrs = %{
                  instrument: instrument,
                  granularity: granularity,
                  strategy_type: strategy_type,
                  parameters: parameters
                }

                case Coordinator.submit_evo_seed(attrs) do
                  {:ok, config} ->
                    Mix.shell().info(
                      "  [seed] #{strategy_type} #{instrument} #{granularity} → #{config.id}"
                    )

                    {s2 + 1, sk2, f2}

                  {:error, reason} ->
                    Mix.shell().error(
                      "  [FAIL] #{strategy_type} #{instrument} #{granularity}: #{inspect(reason)}"
                    )

                    {s2, sk2, f2 + 1}
                end
              end

            "rsi2_dipbuy" ->
              cond do
                instrument not in @rsi2_instruments ->
                  {s2, sk2, f2}

                already_seeded?(instrument, strategy_type, granularity, nil) ->
                  Mix.shell().info(
                    "  [skip] #{strategy_type} #{instrument} #{granularity} — lineage exists"
                  )

                  {s2, sk2 + 1, f2}

                true ->
                  parameters =
                    resolve_params(
                      strategy_type,
                      instrument,
                      granularity,
                      params_for_gran[strategy_type]
                    )

                  attrs = %{
                    instrument: instrument,
                    granularity: granularity,
                    strategy_type: strategy_type,
                    parameters: parameters
                  }

                  case Coordinator.submit_evo_seed(attrs) do
                    {:ok, config} ->
                      Mix.shell().info(
                        "  [seed] #{strategy_type} #{instrument} #{granularity} → #{config.id}"
                      )

                      {s2 + 1, sk2, f2}

                    {:error, reason} ->
                      Mix.shell().error(
                        "  [FAIL] #{strategy_type} #{instrument} #{granularity}: #{inspect(reason)}"
                      )

                      {s2, sk2, f2 + 1}
                  end
              end

            _other ->
              if already_seeded?(instrument, strategy_type, granularity, nil) do
                Mix.shell().info(
                  "  [skip] #{strategy_type} #{instrument} #{granularity} — lineage exists"
                )

                {s2, sk2 + 1, f2}
              else
                parameters =
                  resolve_params(
                    strategy_type,
                    instrument,
                    granularity,
                    params_for_gran[strategy_type]
                  )

                attrs = %{
                  instrument: instrument,
                  granularity: granularity,
                  strategy_type: strategy_type,
                  parameters: parameters
                }

                case Coordinator.submit_evo_seed_exploratory(attrs) do
                  {:ok, config} ->
                    Mix.shell().info(
                      "  [seed] #{strategy_type} #{instrument} #{granularity} → #{config.id}"
                    )

                    {s2 + 1, sk2, f2}

                  {:error, reason} ->
                    Mix.shell().error(
                      "  [FAIL] #{strategy_type} #{instrument} #{granularity}: #{inspect(reason)}"
                    )

                    {s2, sk2, f2 + 1}
                end
              end
          end
        end)
      end)

    Mix.shell().info(
      "\nDone: #{submitted} submitted, #{skipped} skipped (already running), #{failed} failed"
    )
  end

  defp already_seeded?(instrument, strategy_type, granularity, slow_period) do
    Repo.exists?(
      from c in StrategyConfig,
        where:
          c.instrument == ^instrument and
            c.granularity == ^granularity and
            c.strategy_type == ^strategy_type and
            c.evo_generation == 0 and
            not is_nil(c.lineage_id) and
            (^is_nil(slow_period) or
               fragment(
                 "?->'components'->'tf'->'params'->>'slow_period' = ?",
                 c.parameters,
                 ^to_string(slow_period)
               ))
    )
  end

  defp clean_pipeline do
    Repo.transaction(fn ->
      Repo.delete_all("strategy_evaluations")
      Repo.delete_all("strategy_configs")

      from(j in "oban_jobs",
        where: j.queue in ["pipeline", "ollama"] and j.state not in ["completed", "discarded"]
      )
      |> Repo.delete_all()
    end)

    Mix.shell().info("  Truncated strategy_configs, strategy_evaluations, pending pipeline jobs.")
  end
end
