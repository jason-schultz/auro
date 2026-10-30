defmodule Opus.Accounts.HoldingsPriceWorkerTest do
  use ExUnit.Case, async: true

  alias Opus.Accounts.HoldingsPriceWorker

  # Thursday Oct 29, 2026 (EDT, New York = UTC − 4).
  test "re-prices only in the New York session, close included" do
    refute HoldingsPriceWorker.in_session?(~U[2026-10-29 13:15:00Z])
    assert HoldingsPriceWorker.in_session?(~U[2026-10-29 13:30:00Z])
    assert HoldingsPriceWorker.in_session?(~U[2026-10-29 20:00:00Z])
    refute HoldingsPriceWorker.in_session?(~U[2026-10-29 20:15:00Z])
  end

  test "does nothing on a day the market is closed" do
    # Saturday, and Thanksgiving (Nov 26, 2026).
    refute HoldingsPriceWorker.in_session?(~U[2026-10-31 15:00:00Z])
    refute HoldingsPriceWorker.in_session?(~U[2026-11-26 16:00:00Z])
  end
end
