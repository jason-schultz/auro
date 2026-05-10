defmodule Mix.Tasks.Pipeline.Seed do
  @shortdoc "Seeds the pipeline with starting configs for all 42 instruments × both strategies"

  @moduledoc """
  Seeds the pipeline with initial strategy configs.

  Usage:
    mix pipeline.seed                      # H1 (default)
    mix pipeline.seed --granularity H4
    mix pipeline.seed --granularity M15

  Skips instrument/strategy/granularity combos that already have a root config
  (source=manual, no parent). Safe to re-run after a partial seed.
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

  # Starting params tuned per granularity.
  # H4: wider MA windows (candle-count periods; 10/30 at H4 = 40h/120h swing).
  # M15: MR entry_threshold loosened so we get enough trades for evaluation.
  @seed_params %{
    "H1" => %{
      "trend_following" => %{
        "fast_period" => 10,
        "slow_period" => 30,
        "stop_loss" => -0.02,
        "take_profit" => nil
      },
      "mean_reversion" => %{
        "ma_period" => 20,
        "entry_threshold" => -0.005,
        "exit_threshold" => 0.003,
        "stop_loss" => -0.01
      }
    },
    "H4" => %{
      "trend_following" => %{
        "fast_period" => 10,
        "slow_period" => 30,
        "stop_loss" => -0.025,
        "take_profit" => nil
      },
      "mean_reversion" => %{
        "ma_period" => 20,
        "entry_threshold" => -0.008,
        "exit_threshold" => 0.005,
        "stop_loss" => -0.015
      }
    },
    "M15" => %{
      "trend_following" => %{
        "fast_period" => 10,
        "slow_period" => 30,
        "stop_loss" => -0.015,
        "take_profit" => nil
      },
      "mean_reversion" => %{
        "ma_period" => 20,
        "entry_threshold" => -0.003,
        "exit_threshold" => 0.002,
        "stop_loss" => -0.008
      }
    }
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    granularity = parse_granularity(args)
    params_for_gran = Map.fetch!(@seed_params, granularity)

    Mix.shell().info("Seeding pipeline for granularity=#{granularity} (#{length(@instruments)} instruments × #{map_size(params_for_gran)} strategies)\n")

    combinations =
      for instrument <- @instruments,
          {strategy_type, _params} <- params_for_gran,
          do: {instrument, strategy_type}

    {submitted, skipped} =
      Enum.reduce(combinations, {0, 0}, fn {instrument, strategy_type}, {s, sk} ->
        if already_seeded?(instrument, strategy_type, granularity) do
          {s, sk + 1}
        else
          attrs = %{
            instrument: instrument,
            granularity: granularity,
            strategy_type: strategy_type,
            parameters: params_for_gran[strategy_type],
            source: "manual"
          }

          case Coordinator.submit_config(attrs) do
            {:ok, config} ->
              Mix.shell().info("[seed] #{strategy_type} #{instrument} #{granularity} → #{config.id}")
              {s + 1, sk}

            {:error, reason} ->
              Mix.shell().error("[seed] FAILED #{strategy_type} #{instrument} #{granularity}: #{inspect(reason)}")
              {s, sk}
          end
        end
      end)

    Mix.shell().info("\nDone: #{submitted} submitted, #{skipped} already seeded")
  end

  defp parse_granularity(args) do
    case Enum.find_index(args, &(&1 in ["--granularity", "-g"])) do
      nil ->
        "H1"

      idx ->
        gran = Enum.at(args, idx + 1)

        unless Map.has_key?(@seed_params, gran) do
          Mix.shell().error("Unknown granularity: #{inspect(gran)}. Valid: #{Map.keys(@seed_params) |> Enum.join(", ")}")
          exit(:shutdown)
        end

        gran
    end
  end

  defp already_seeded?(instrument, strategy_type, granularity) do
    Repo.exists?(
      from c in StrategyConfig,
        where:
          c.instrument == ^instrument and
            c.granularity == ^granularity and
            c.strategy_type == ^strategy_type and
            c.source == "manual" and
            is_nil(c.parent_config_id)
    )
  end
end
