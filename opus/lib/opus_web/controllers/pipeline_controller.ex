defmodule OpusWeb.PipelineController do
  use OpusWeb, :controller

  alias Opus.Pipeline.Coordinator

  @stage_order %{"monte_carlo" => 3, "walk_forward" => 2, "backtest" => 1}

  def promote(conn, %{"config_id" => config_id} = params) do
    max_position_size = Map.get(params, "max_position_size", "1000")

    case Coordinator.promote_to_live(config_id, max_position_size) do
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
    end
  end

  def index(conn, _params) do
    rows = Coordinator.list_pipeline_status()

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
          depth: first.depth,
          parent_config_id: first.parent_config_id,
          stage: latest && latest.stage,
          status: latest && latest.status,
          stats: latest && latest.stats,
          failure_reason: latest && latest.failure_reason,
          evaluations: evaluations
        }
      end)
      |> Enum.sort_by(&{&1.instrument, &1.strategy_type, &1.depth})

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
      Enum.reduce(configs, %{backtest: 0, walk_forward: 0, monte_carlo: 0}, fn c, acc ->
        case c.stage do
          nil -> acc
          stage -> Map.update(acc, String.to_existing_atom(stage), 1, &(&1 + 1))
        end
      end)

    Map.merge(%{total: total}, Map.merge(by_status, furthest_stage))
  end
end
