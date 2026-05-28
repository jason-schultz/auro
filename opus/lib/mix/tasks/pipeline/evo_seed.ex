defmodule Mix.Tasks.Pipeline.EvoSeed do
  @shortdoc "Start evolutionary lineages for all instruments × strategies (exploratory mode)"

  @moduledoc """
  Seeds the pipeline with exploratory evo lineages for all instrument/strategy
  combinations. Uses submit_evo_seed_exploratory/1 so the seed itself is not
  backtested — generation-1 children are spawned immediately with mutated params.

  Usage:
    mix pipeline.evo_seed                        # H1, both strategies
    mix pipeline.evo_seed --granularity H4
    mix pipeline.evo_seed --granularity M15
    mix pipeline.evo_seed --granularity M5
    mix pipeline.evo_seed --strategy mean_reversion         # only MR
    mix pipeline.evo_seed --strategy trend_following        # only TF
    mix pipeline.evo_seed --strategy mean_reversion --granularity H1
    mix pipeline.evo_seed --clean                # truncate all pipeline data first
    mix pipeline.evo_seed --clean --granularity H1

  --clean truncates strategy_configs, strategy_evaluations, and pending/running
  pipeline Oban jobs before seeding. Does NOT touch live_strategies.

  --strategy restricts the run to a single strategy type. Valid values:
    "mean_reversion", "trend_following". Omit to seed both.

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

  # Seed params per strategy class. Both TF and MR now use the composite shape
  # — see decision-canonical-strategy-shape. TF v1 ships fixed 50/200 (no
  # mutation, textbook Britannica baseline). MR v1 evolves around the textbook
  # Investopedia params via the spawner mutator.
  @seed_params %{
    "H1" => %{
      "trend_following" => :composite_tf_v1,
      "mean_reversion" => :composite_mr_v1
    },
    "H4" => %{
      "trend_following" => :composite_tf_v1,
      "mean_reversion" => :composite_mr_v1
    },
    "M15" => %{
      "trend_following" => :composite_tf_v1,
      "mean_reversion" => :composite_mr_v1
    },
    "M5" => %{
      "trend_following" => :composite_tf_v1,
      "mean_reversion" => :composite_mr_v1
    }
  }

  # Build the composite-shape Strategy JSON for TF v1.
  # 50/200 is the Britannica golden-cross textbook standard.
  # stop_loss_pct -0.02 is not from textbook — it's a standard practitioner
  # default; documented as judgment, not citation.
  defp build_tf_v1_composite(instrument, granularity) do
    %{
      "strategy_id" => nil,
      "strategy_name" => "tf_v1_#{instrument}_#{granularity}",
      "version" => "v1_composite",
      "instrument" => instrument,
      "granularity" => granularity,
      "components" => %{
        "tf" => %{
          "type" => "TrendFollowing",
          "params" => %{"fast_period" => 50, "slow_period" => 200}
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
      "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}},
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

  defp resolve_params(strategy_type, instrument, granularity, seed) do
    case seed do
      :composite_tf_v1 ->
        build_tf_v1_composite(instrument, granularity)

      :composite_mr_v1 ->
        build_mr_v1_composite(instrument, granularity)

      params when is_map(params) ->
        params

      other ->
        raise "unsupported seed config for #{strategy_type}: #{inspect(other)}"
    end
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

    total_combos = length(@instruments) * length(strategies)

    Mix.shell().info(
      "Seeding evo lineages: #{length(@instruments)} instruments × #{length(strategies)} strategies " <>
        "(#{granularity}) = #{total_combos} combos\n"
    )

    {submitted, skipped, failed} =
      Enum.reduce(@instruments, {0, 0, 0}, fn instrument, {s, sk, f} ->
        Enum.reduce(strategies, {s, sk, f}, fn strategy_type, {s2, sk2, f2} ->
          if already_seeded?(instrument, strategy_type, granularity) do
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

            # TF v1 is composite-shape and does NOT evolve (textbook 50/200 fixed).
            # Use submit_evo_seed (non-exploratory) so the seed itself is backtested
            # and the spawner promotes it directly without mutating gen-1 children.
            # MR continues to use exploratory mode for evo.
            submit_fn =
              case strategy_type do
                "trend_following" -> &Coordinator.submit_evo_seed/1
                _ -> &Coordinator.submit_evo_seed_exploratory/1
              end

            case submit_fn.(attrs) do
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
        end)
      end)

    Mix.shell().info(
      "\nDone: #{submitted} submitted, #{skipped} skipped (already running), #{failed} failed"
    )
  end

  defp already_seeded?(instrument, strategy_type, granularity) do
    Repo.exists?(
      from c in StrategyConfig,
        where:
          c.instrument == ^instrument and
            c.granularity == ^granularity and
            c.strategy_type == ^strategy_type and
            c.evo_generation == 0 and
            not is_nil(c.lineage_id)
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
