defmodule Opus.Accounts.IndexExposureTest do
  use ExUnit.Case, async: true

  alias Opus.Accounts.IndexExposure

  @month ~D[2026-09-01]

  # The close before the month, then one close per weekday with returns
  # alternating ±move.
  defp closes(move) do
    days =
      Date.range(~D[2026-09-01], ~D[2026-09-30])
      |> Enum.filter(&(Date.day_of_week(&1) <= 5))

    {pairs, _} =
      days
      |> Enum.with_index()
      |> Enum.map_reduce(100.0, fn {date, i}, price ->
        next = price * if(rem(i, 2) == 0, do: 1 + move, else: 1 - move)
        {{date, next}, next}
      end)

    [{~D[2026-08-31], 100.0} | pairs]
  end

  test "a calm month is held in full" do
    # 0.5% daily moves: about 7.9% annualized.
    result = IndexExposure.for_month(closes(0.005), @month)

    assert_in_delta result.realized_vol, 0.005 * :math.sqrt(252), 1.0e-9
    assert result.exposure == 1.0
  end

  test "a volatile month scales exposure by target variance over realized" do
    # 2% daily moves: about 31.7% annualized, so (0.16 / 0.317)² ≈ 25%.
    result = IndexExposure.for_month(closes(0.02), @month)

    assert_in_delta result.exposure, 0.16 * 0.16 / (0.02 * 0.02 * 252), 1.0e-9
  end

  test "only returns ending inside the month count" do
    with_next_month = closes(0.005) ++ [{~D[2026-10-01], 200.0}]

    assert IndexExposure.for_month(with_next_month, @month) ==
             IndexExposure.for_month(closes(0.005), @month)
  end

  test "a month without a single move is held in full, not divided by zero" do
    result = IndexExposure.for_month(closes(0.0), @month)

    assert result.realized_vol == 0.0
    assert result.exposure == 1.0
  end

  test "no bars, no answer" do
    assert IndexExposure.for_month([], @month) == nil
  end
end
