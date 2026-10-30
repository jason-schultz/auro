defmodule Opus.Pipeline.ParameterStabilityWorkerTest do
  # Not async: the engine's address is application config.
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Pipeline.{HoldoutWorker, MonteCarloWorker, ParameterStabilityWorker}

  # A stand-in engine: answers `path` with one stage result, anything else 404.
  defmodule Engine do
    @behaviour Plug

    @impl true
    def init(answer), do: answer

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, {path, result}) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(result))
    end

    def call(conn, _answer), do: Plug.Conn.send_resp(conn, 404, "")
  end

  # config/test.exs points the tester at a closed port; for one test, point
  # it at a stand-in tester instead. Pipeline stages never go to the live
  # engine's address.
  defp engine_answers(path, result) do
    pid =
      start_supervised!(
        {Bandit, plug: {Engine, {path, result}}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.fetch_env!(:opus, :auro_tester_url)
    on_exit(fn -> Application.put_env(:opus, :auro_tester_url, previous) end)
    Application.put_env(:opus, :auro_tester_url, "http://127.0.0.1:#{port}")
  end

  setup do
    %{config_id: Ecto.UUID.generate()}
  end

  test "a Monte Carlo pass goes on to parameter stability, not straight to the holdout",
       %{config_id: id} do
    engine_answers("/api/pipeline/monte_carlo", %{"status" => "passed", "stats" => %{}})

    assert :ok = perform_job(MonteCarloWorker, %{"config_id" => id})

    assert_enqueued(worker: ParameterStabilityWorker, args: %{config_id: id})
    refute_enqueued(worker: HoldoutWorker)
  end

  test "a parameter-stability pass goes on to the holdout", %{config_id: id} do
    engine_answers("/api/pipeline/parameter_stability", %{
      "status" => "passed",
      "stats" => %{"tested" => 6, "worst_sharpe_retention" => 0.8}
    })

    assert :ok = perform_job(ParameterStabilityWorker, %{"config_id" => id})

    assert_enqueued(worker: HoldoutWorker, args: %{config_id: id})
  end

  test "a parameter-stability failure ends the run", %{config_id: id} do
    engine_answers("/api/pipeline/parameter_stability", %{
      "status" => "failed",
      "failure_reason" => "Moving rsi period (r, RsiReversion) from 2 to 3 dropped the Sharpe"
    })

    assert :ok = perform_job(ParameterStabilityWorker, %{"config_id" => id})

    refute_enqueued(worker: HoldoutWorker)
  end

  @tag :capture_log
  test "a tester that isn't running makes the stage wait, not fail or pass", %{config_id: id} do
    assert {:snooze, _seconds} = perform_job(ParameterStabilityWorker, %{"config_id" => id})
    refute_enqueued(worker: HoldoutWorker)
  end

  @tag :capture_log
  test "a tester error that isn't 'not running' is still an error", %{config_id: id} do
    # The stand-in answers only Monte Carlo: this stage gets a 404.
    engine_answers("/api/pipeline/monte_carlo", %{"status" => "passed", "stats" => %{}})

    assert {:error, {:http_error, 404, _}} =
             perform_job(ParameterStabilityWorker, %{"config_id" => id})

    refute_enqueued(worker: HoldoutWorker)
  end
end
