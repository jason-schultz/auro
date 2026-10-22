defmodule Opus.Trading.RiskMood do
  @moduledoc """
  Market-wide risk mood from AUD/JPY's 5-day return — the cross-asset regime
  the 2026-10 sweep found useful for gating trend sleeves (trend did better
  in risk-on on indices, bonds and metals; not on energy/ags). Computed from
  Rust's indicators endpoint (daily candles), fail-closed to `:unknown`.
  """

  require Logger

  alias Opus.Auro.Client

  @leader "AUD_JPY"
  @lookback_days 5

  @type t :: :risk_on | :risk_off | :unknown

  @spec current() :: t()
  def current do
    case Client.get_indicators(@leader, "D", roc_period: @lookback_days) do
      {:ok, %{"indicators" => %{"roc_pct" => roc}}} when is_number(roc) ->
        from_roc(roc)

      other ->
        Logger.warning("[RiskMood] unavailable: #{inspect(other)}")
        :unknown
    end
  end

  @spec from_roc(number()) :: t()
  def from_roc(roc) when roc > 0, do: :risk_on
  def from_roc(_roc), do: :risk_off
end
