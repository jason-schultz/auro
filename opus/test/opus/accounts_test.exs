defmodule Opus.AccountsTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.{Accounts, Instruments}
  alias Opus.MarketData.ShareHistoryWorker

  test "a holding of a symbol not in the instruments is added as a stock, and fed" do
    {:ok, _} = Instruments.add("FLT.TO", "equity")

    payload = [
      %{positions: [%{symbol: "FLT.TO"}, %{symbol: "NEW.TO"}]},
      %{positions: [%{symbol: "NEW.TO"}]}
    ]

    assert Accounts.track(payload) == ["NEW.TO"]
    assert Instruments.known?("NEW.TO")
    assert_enqueued(worker: ShareHistoryWorker)
    assert Accounts.track(payload) == []
  end
end
