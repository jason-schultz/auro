defmodule Opus.Settings.StatusTest do
  use Opus.DataCase, async: true

  alias Opus.Settings
  alias Opus.Settings.Status

  @oanda Settings.integration("oanda-practice")
  @massive Settings.integration("massive")

  defp known(engine, questrade \\ nil), do: %{engine: engine, questrade: questrade, views: %{}}

  test "an engine connection says what the engine reports, never just what's saved" do
    assert {:checking, _, _} = Status.of(@oanda, known(nil))

    assert {:unknown, _, "Couldn't ask the engine: down"} =
             Status.of(@oanda, known({:error, "down"}))

    assert {:working, "In use", "In use since " <> _} =
             Status.of(
               @oanda,
               known({:ok, %{"oanda" => %{"in_use_since" => "2026-11-01T22:35:00Z"}}})
             )

    assert {:problem, "Problem", "OANDA refused it."} =
             Status.of(
               @oanda,
               known({:ok, %{"oanda" => %{"ok" => false, "words" => "OANDA refused it."}}})
             )

    assert {:restart, _, "Applies on restart."} =
             Status.of(
               @oanda,
               known(
                 {:ok,
                  %{"oanda" => %{"restart_to_switch" => true, "words" => "Applies on restart."}}}
               )
             )

    assert {:none, "Not set up", _} = Status.of(@massive, known({:ok, %{}}))
  end

  test "Questrade follows the engine's connection" do
    q = Settings.integration("questrade")
    assert {:working, "Connected", _} = Status.of(q, known(nil, {:ok, %{"connected" => true}}))

    assert {:problem, "Not connected", "Not connected: token refused"} =
             Status.of(q, known(nil, {:ok, %{"connected" => false, "error" => "token refused"}}))
  end

  test "only problems and account switches need attention" do
    statuses = %{
      "oanda" => %{"in_use_since" => "2026-11-01T22:35:00Z"},
      "massive" => %{"ok" => false, "words" => "Massive refused it."}
    }

    assert [{%{id: "massive"}, "Massive refused it."}] =
             Status.needing_attention(known({:ok, statuses}, {:ok, %{"connected" => true}}))
  end
end
