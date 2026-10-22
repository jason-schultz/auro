defmodule Opus.Trading.RegimeGateTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.{RegimeGate, RiskMood}

  test "no gate is always open" do
    assert {true, _} = RegimeGate.evaluate(nil, %{risk_mood: :unknown})
    assert {true, _} = RegimeGate.evaluate(%{}, %{risk_mood: :risk_off})
  end

  test "risk_mood gate opens only on the wanted mood" do
    gate = %{"risk_mood" => "risk_on"}
    assert {true, reason} = RegimeGate.evaluate(gate, %{risk_mood: :risk_on})
    assert reason =~ "open"
    assert {false, reason} = RegimeGate.evaluate(gate, %{risk_mood: :risk_off})
    assert reason =~ "closed"
  end

  test "unknown mood and unknown keys fail closed" do
    assert {false, _} = RegimeGate.evaluate(%{"risk_mood" => "risk_on"}, %{risk_mood: :unknown})
    assert {false, reason} = RegimeGate.evaluate(%{"vol" => "high"}, %{risk_mood: :risk_on})
    assert reason =~ "unsupported gate vol"
  end

  test "risk mood follows the sign of the AUD/JPY return" do
    assert RiskMood.from_roc(0.4) == :risk_on
    assert RiskMood.from_roc(-0.4) == :risk_off
    assert RiskMood.from_roc(0) == :risk_off
  end
end
