defmodule Opus.Trading.ReconcilerTest do
  use Opus.DataCase, async: false

  alias Opus.Repo
  alias Opus.Trading.Reconciler

  # OANDA answers from a Req.Test stub (config/test.exs); the Rust engine is a
  # closed port, so every engine delete fails here.

  setup do
    Repo.query!("DELETE FROM live_trades")
    :ok
  end

  defp open_trade(oanda_id) do
    now = DateTime.utc_now()

    Repo.insert_all("live_trades", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        oanda_trade_id: oanda_id,
        instrument: "EUR_USD",
        direction: "Long",
        units: "1000",
        status: "open",
        entry_price: 1.1,
        entry_time: DateTime.add(now, -7200),
        created_at: now,
        updated_at: now
      }
    ])
  end

  defp stub_oanda(trade) do
    Req.Test.stub(Opus.Oanda.Client, fn conn ->
      if String.ends_with?(conn.request_path, "/openTrades"),
        do: Req.Test.json(conn, %{"trades" => []}),
        else: Req.Test.json(conn, %{"trade" => trade})
    end)
  end

  defp exit_time(oanda_id) do
    from(t in "live_trades",
      where: t.oanda_trade_id == ^oanda_id,
      select: {t.status, type(t.exit_time, :utc_datetime_usec)}
    )
    |> Repo.one()
  end

  @tag :capture_log
  test "a trade OANDA closed is closed at OANDA's close time" do
    open_trade("42")

    stub_oanda(%{
      "id" => "42",
      "state" => "CLOSED",
      "averageClosePrice" => "1.1050",
      "realizedPL" => "5.0",
      "closeTime" => "2026-10-27T14:03:07.123456789Z",
      "stopLossOrder" => %{"state" => "FILLED", "price" => "1.0"}
    })

    assert {:ok, 1, _pending} = Reconciler.reconcile_once()
    assert {"closed", ~U[2026-10-27 14:03:07.123456Z]} = exit_time("42")
  end

  @tag :capture_log
  test "a failed engine delete is kept and retried on later ticks" do
    open_trade("43")

    stub_oanda(%{
      "id" => "43",
      "state" => "CLOSED",
      "averageClosePrice" => "1.1050",
      "realizedPL" => "5.0"
    })

    # The engine is unreachable: the row closes, the delete stays pending.
    assert {:ok, 1, pending} = Reconciler.reconcile_once()
    assert MapSet.to_list(pending) == ["43"]
    # No close time from OANDA: closed now instead.
    assert {"closed", %DateTime{}} = exit_time("43")

    # The next tick finds nothing new to close but retries the delete.
    assert {:ok, 0, ^pending} = Reconciler.reconcile_once(pending)
  end
end
