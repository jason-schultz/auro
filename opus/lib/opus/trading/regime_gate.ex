defmodule Opus.Trading.RegimeGate do
  @moduledoc """
  Opt-in regime gate for composite strategies. A composite's parameters may
  carry `"regime_gate"`, e.g. `%{"risk_mood" => "risk_on"}`; the strategy is
  allowed to trade only while every listed condition holds. Composites
  without a gate stay self-gated (always allowed by regime).

  Unknown market state fails closed, matching the rules engine's policy.
  Unknown gate keys also fail closed so a typo can't silently disable gating.
  """

  @type market :: %{risk_mood: Opus.Trading.RiskMood.t()}

  @spec evaluate(map() | nil, market()) :: {boolean(), String.t()}
  def evaluate(nil, _market), do: {true, "no regime gate"}
  def evaluate(gate, _market) when gate == %{}, do: {true, "no regime gate"}

  def evaluate(gate, market) when is_map(gate) do
    results = Enum.map(gate, fn {key, want} -> check(key, want, market) end)

    case Enum.reject(results, &elem(&1, 0)) do
      [] -> {true, "regime gate open — " <> Enum.map_join(results, ", ", &elem(&1, 1))}
      failed -> {false, "regime gate closed — " <> Enum.map_join(failed, ", ", &elem(&1, 1))}
    end
  end

  defp check("risk_mood", want, %{risk_mood: :unknown}),
    do: {false, "risk_mood unknown (want #{want})"}

  defp check("risk_mood", want, %{risk_mood: mood}) when want in ["risk_on", "risk_off"],
    do: {Atom.to_string(mood) == want, "risk_mood=#{mood} (want #{want})"}

  defp check(key, want, _market), do: {false, "unsupported gate #{key}=#{inspect(want)}"}
end
