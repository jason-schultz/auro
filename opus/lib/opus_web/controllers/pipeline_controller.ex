defmodule OpusWeb.PipelineController do
  use OpusWeb, :controller

  alias Opus.Auro.Client, as: Auro
  alias Opus.Pipeline.Coordinator
  alias Opus.Pipeline.StrategyConfig
  alias Opus.Repo

  @stage_order %{
    "holdout" => 5,
    "parameter_stability" => 4,
    "monte_carlo" => 3,
    "walk_forward" => 2,
    "backtest" => 1
  }

  @doc """
  Create a manually-authored strategy config (Strategy Editor). Enters the
  same `strategy_configs` table the pipeline uses, with `source: "manual"`,
  so validation stages and promotion reuse the existing machinery.
  """
  def create_config(conn, params) do
    attrs = %{
      source: "manual",
      instrument: params["instrument"],
      granularity: params["granularity"],
      strategy_type: Map.get(params, "strategy_type", "composite"),
      parameters: params["parameters"]
    }

    with nil <- Opus.Pipeline.Coordinator.untestable(attrs),
         {:ok, config} <- %StrategyConfig{} |> StrategyConfig.changeset(attrs) |> Repo.insert() do
      json(conn, %{config_id: config.id})
    else
      # Its markets can't be tested yet: say why now, not when a stage fails.
      {kind, _names} = why when kind in [:no_broker, :no_dividends] ->
        conn
        |> put_status(422)
        |> json(%{error: "not testable", details: Opus.Instruments.untestable_words(why)})

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        conn
        |> put_status(422)
        |> json(%{error: "invalid config", details: errors})
    end
  end

  @doc """
  Run one validation stage for a config against the Rust engine. Stages are
  the pipeline's own: backtest, walk_forward, monte_carlo, parameter_stability,
  holdout. The Rust side
  persists the strategy_evaluations row; the stage result is returned as-is.
  """
  def run_stage(conn, %{"config_id" => config_id, "stage" => stage}) do
    result =
      case stage do
        "backtest" -> Auro.run_pipeline_backtest(config_id)
        "walk_forward" -> Auro.run_pipeline_walk_forward(config_id)
        "monte_carlo" -> Auro.run_pipeline_monte_carlo(config_id)
        "parameter_stability" -> Auro.run_pipeline_parameter_stability(config_id)
        "holdout" -> Auro.run_pipeline_holdout(config_id)
        _ -> {:error, :invalid_stage}
      end

    case result do
      {:ok, body} ->
        json(conn, body)

      {:error, :invalid_stage} ->
        conn
        |> put_status(400)
        |> json(%{
          error:
            "invalid stage: #{stage} " <>
              "(expected backtest|walk_forward|monte_carlo|parameter_stability|holdout)"
        })

      {:error, :tester_down} ->
        conn
        |> put_status(503)
        |> json(%{error: Auro.describe_error(:tester_down)})

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "stage run failed: #{inspect(reason)}"})
    end
  end

  def promote(conn, %{"config_id" => config_id}) do
    case Coordinator.promote_to_live(config_id) do
      {:ok, :promoted} ->
        json(conn, %{promoted: true, config_id: config_id})

      {:ok, :already_promoted} ->
        conn
        |> put_status(409)
        |> json(%{error: "Already promoted — this strategy is already in live_strategies."})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Pipeline config not found."})

      {:error, :basket} ->
        conn
        |> put_status(422)
        |> json(%{error: "A basket is tested, not traded live, so it can't be promoted."})

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "promotion failed: #{inspect(reason)}"})
    end
  end

  @doc """
  Every config and its stages. Configs archived as tried before the block
  builder are left out unless `?archive=true`; `summary.archived` says how
  many there are either way.
  """
  def index(conn, params) do
    rows = Coordinator.list_pipeline_status(params["archive"] in ["true", "1"])

    configs =
      rows
      |> Enum.group_by(& &1.config_id)
      |> Enum.map(fn {_id, rows} ->
        first = List.first(rows)

        evaluations =
          rows
          |> Enum.filter(& &1.stage)
          |> Enum.map(fn r ->
            %{stage: r.stage, status: r.status, stats: r.stats, failure_reason: r.failure_reason}
          end)

        latest =
          evaluations
          |> Enum.sort_by(&Map.get(@stage_order, &1.stage, 0), :desc)
          |> List.first()

        %{
          config_id: first.config_id,
          instrument: first.instrument,
          granularity: first.granularity,
          strategy_type: first.strategy_type,
          parameters: first.parameters,
          source: first.source,
          inserted_at: first.inserted_at,
          archived: first.archived,
          stage: latest && latest.stage,
          status: latest && latest.status,
          stats: latest && latest.stats,
          failure_reason: latest && latest.failure_reason,
          evaluations: evaluations
        }
      end)
      |> Enum.sort_by(&{&1.instrument, &1.strategy_type, &1.granularity})

    summary = build_summary(configs)

    json(conn, %{summary: summary, configs: configs})
  end

  defp build_summary(configs) do
    total = length(configs)

    by_status =
      Enum.reduce(configs, %{pending: 0, running: 0, passed: 0, failed: 0}, fn c, acc ->
        key = (c.status || "pending") |> String.to_existing_atom()
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    furthest_stage =
      Enum.reduce(
        configs,
        %{backtest: 0, walk_forward: 0, monte_carlo: 0, parameter_stability: 0, holdout: 0},
        fn c, acc ->
          case c.stage do
            nil -> acc
            stage -> Map.update(acc, String.to_existing_atom(stage), 1, &(&1 + 1))
          end
        end
      )

    %{total: total, archived: Coordinator.count_archived()}
    |> Map.merge(by_status)
    |> Map.merge(furthest_stage)
  end
end
