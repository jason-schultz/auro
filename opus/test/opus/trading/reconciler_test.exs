# defmodule Opus.Trading.ReconcilerTest do
#   use ExUnit.Case, async: true

#   alias Opus.Trading.Reconciler

#   describe "determine_exit_reason/1" do
#     test "returns StopLoss when stopLossOrder is FILLED" do
#       trade_data = %{
#         "stopLossOrder" => %{"state" => "FILLED"}
#       }

#       assert Reconciler.determine_exit_reason(trade_data) == "StopLoss"
#     end

#     test "returns TakeProfit when takeProfitOrder is FILLED" do
#       trade_data = %{
#         "takeProfitOrder" => %{"state" => "FILLED"}
#       }

#       assert Reconciler.determine_exit_reason(trade_data) == "TakeProfit"
#     end

#     test "returns TrailingStop when trailingStopLossOrder is FILLED" do
#       trade_data = %{
#         "trailingStopLossOrder" => %{"state" => "FILLED"}
#       }

#       assert Reconciler.determine_exit_reason(trade_data) == "TrailingStop"
#     end

#     test "returns ClosedByBroker when no order is FILLED" do
#       trade_data = %{
#         "stopLossOrder" => %{"state" => "PENDING"},
#         "takeProfitOrder" => %{"state" => "CANCELLED"}
#       }

#       assert Reconciler.determine_exit_reason(trade_data) == "ClosedByBroker"
#     end

#     test "returns ClosedByBroker when trade_data is empty" do
#       assert Reconciler.determine_exit_reason(%{}) == "ClosedByBroker"
#     end

#     test "prefers StopLoss over TakeProfit when both are FILLED" do
#       # Shouldn't happen in practice, but verifies cond ordering is deterministic
#       trade_data = %{
#         "stopLossOrder" => %{"state" => "FILLED"},
#         "takeProfitOrder" => %{"state" => "FILLED"}
#       }

#       assert Reconciler.determine_exit_reason(trade_data) == "StopLoss"
#     end
#   end
# end
