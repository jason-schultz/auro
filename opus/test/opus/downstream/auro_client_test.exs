defmodule Opus.Auro.ClientTest do
  # Not async: the engine addresses are application config.
  use ExUnit.Case, async: false

  alias Opus.Auro.Client

  @moduletag :capture_log

  test "test work goes to the tester, live work to the live engine" do
    assert Client.tester_url() == Application.fetch_env!(:opus, :auro_tester_url)
    refute Client.tester_url() == Client.base_url()
  end

  test "the tester address never falls back to the live engine's" do
    previous = Application.fetch_env!(:opus, :auro_tester_url)
    on_exit(fn -> Application.put_env(:opus, :auro_tester_url, previous) end)
    Application.delete_env(:opus, :auro_tester_url)

    assert Client.tester_url() == "http://localhost:3001"
  end

  test "a tester that isn't running is :tester_down, said in plain words" do
    # config/test.exs points the tester at a closed port.
    assert {:error, :tester_down} = Client.strategy_report(%{})
    assert {:error, :tester_down} = Client.run_pipeline_backtest(Ecto.UUID.generate())

    message = Client.describe_error(:tester_down)
    assert message =~ "tester isn't running"
    assert message =~ "auro-tester"
  end

  test "the live engine being down is still described as Auro not running" do
    assert {:error, reason} = Client.get_live_health()
    assert Client.describe_error(reason) == "Auro is not running."
  end
end
