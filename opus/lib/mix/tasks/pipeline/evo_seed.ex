defmodule Mix.Tasks.Pipeline.EvoSeed do
  @shortdoc "Start evolutionary lineages for all instruments × strategies (exploratory mode)"

  @moduledoc """
  Seeds the pipeline with exploratory evo lineages for all instrument/strategy
  combinations. Uses submit_evo_seed_exploratory/1 so the seed itself is not
  backtested — generation-1 children are spawned immediately with mutated params.

  Usage:
    mix pipeline.evo_seed                        # H1, dry-run false
    mix pipeline.evo_seed --granularity M15
    mix pipeline.evo_seed --clean                # truncate all pipeline data first
    mix pipeline.evo_seed --clean --granularity H1

  --clean truncates strategy_configs, strategy_evaluations, and pending/running
  pipeline Oban jobs before seeding. Does NOT touch live_strategies.

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

  # Seed params are the starting point for mutation — exact values matter less
  # in exploratory mode since gen-1 children are immediately mutated.
  @seed_params %{
    "H1" => %{
      "trend_following" => %{
        "fast_period" => 10,
        "slow_period" => 50,
        "stop_loss" => -0.02,
        "take_profit" => nil,
        "regime_filter" => true
      },
      "mean_reversion" => %{
        "ma_period" => 20,
        "entry_threshold" => -0.005,
        "exit_threshold" => 0.003,
        "stop_loss" => -0.01,
        "regime_filter" => true
      }
    },
    "M15" => %{
      "trend_following" => %{
        "fast_period" => 10,
        "slow_period" => 30,
        "stop_loss" => -0.015,
        "take_profit" => nil,
        "regime_filter" => true
      },
      "mean_reversion" => %{
        "ma_period" => 20,
        "entry_threshold" => -0.003,
        "exit_threshold" => 0.002,
        "stop_loss" => -0.008,
        "regime_filter" => true
      }
    }
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args, strict: [clean: :boolean, granularity: :string])

    granularity = Keyword.get(opts, :granularity, "H1")
    clean? = Keyword.get(opts, :clean, false)

    unless Map.has_key?(@seed_params, granularity) do
      Mix.shell().error(
        "Unknown granularity: #{granularity}. Valid: #{Map.keys(@seed_params) |> Enum.join(", ")}"
      )

      exit(:shutdown)
    end

    params_for_gran = Map.fetch!(@seed_params, granularity)
    strategies = Map.keys(params_for_gran)

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
            attrs = %{
              instrument: instrument,
              granularity: granularity,
              strategy_type: strategy_type,
              parameters: params_for_gran[strategy_type]
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
      Repo.query!("TRUNCATE strategy_evaluations")
      Repo.query!("TRUNCATE strategy_configs")

      Repo.query!(
        "DELETE FROM oban_jobs WHERE queue IN ('pipeline', 'ollama') AND state NOT IN ('completed', 'discarded')"
      )
    end)

    Mix.shell().info("  Truncated strategy_configs, strategy_evaluations, pending pipeline jobs.")
  end
end
