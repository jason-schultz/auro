defmodule Opus.Dashboard.NotifyWorkerTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  import Ecto.Query

  alias Opus.Dashboard.NotifyWorker

  @now ~U[2026-10-27 15:00:00Z]

  defp alert(key, level \\ :act),
    do: %{
      level: level,
      key: key,
      title: "T #{key}",
      detail: nil,
      what_to_do: "Nothing",
      link: nil
    }

  defp stub_discord(status \\ 204) do
    test = self()

    Req.Test.stub(Opus.Dashboard.Discord, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp sent_keys,
    do: Repo.all(from(n in "alert_notifications", select: n.key, order_by: n.key))

  test "send_now queues a send per source, not waiting for the 5-minute run" do
    assert {:ok, _job} = NotifyWorker.send_now("options_paper")
    assert {:ok, _job} = NotifyWorker.send_now("options_paper")
    assert {:ok, _job} = NotifyWorker.send_now("options_intraday")

    assert [_, _] = all_enqueued(worker: NotifyWorker)
    assert_enqueued(worker: NotifyWorker, args: %{source: "options_paper"})
  end

  test "an alert is sent once while it stays, and again after an hour gone" do
    stub_discord()

    assert :ok = NotifyWorker.notify([alert("engine")], @now)
    assert_received {:posted, %{"content" => "Act now: T engine", "embeds" => [embed]}}
    assert embed["description"] == "**What to do:** Nothing"

    assert :ok = NotifyWorker.notify([alert("engine")], DateTime.add(@now, 300))
    refute_received {:posted, _}

    # Gone for under an hour: still remembered, so a flicker doesn't ping.
    assert :ok = NotifyWorker.notify([], DateTime.add(@now, 1800))
    assert :ok = NotifyWorker.notify([alert("engine")], DateTime.add(@now, 2400))
    refute_received {:posted, _}

    # Gone for over an hour: forgotten, so it's sent when it comes back.
    assert :ok = NotifyWorker.notify([], DateTime.add(@now, 2400 + 3601))
    assert sent_keys() == []
    assert :ok = NotifyWorker.notify([alert("engine")], DateTime.add(@now, 7200))
    assert_received {:posted, _}
  end

  test "the ideas scan isn't sent, and more than ten alerts split into messages" do
    stub_discord()

    alerts = [alert("ideas:2026-10-24", :fyi) | Enum.map(1..12, &alert("k#{&1}", :check))]
    assert :ok = NotifyWorker.notify(alerts, @now)

    assert_received {:posted, %{"embeds" => first}}
    assert_received {:posted, %{"embeds" => second}}
    assert {length(first), length(second)} == {10, 2}
    refute "ideas:2026-10-24" in sent_keys()
  end

  test "a failed post records nothing, so it's tried again" do
    stub_discord(500)

    assert {:error, {500, _}} = NotifyWorker.notify([alert("engine")], @now)
    assert sent_keys() == []
  end

  test "the check-in says all quiet, or lists what to look at" do
    gathered = %{
      input: %{now: ~U[2026-10-27 20:30:00Z], engine: :up},
      positions: [%{book: "live"}, %{book: "wheel"}, %{book: "put_spread"}],
      books: [%{pnl: -150.0}, %{pnl: 10.0}],
      live: %{open_trades: 1}
    }

    assert NotifyWorker.check_in(gathered, [alert("ideas:x", :fyi)]) ==
             {"Auro check-in, Oct 27: all quiet",
              ["Engine: running", "Open: 2 paper, 1 live", "Paper books so far: −$140.00"]}

    {title, lines} = NotifyWorker.check_in(gathered, [alert("engine")])
    assert title == "Auro check-in, Oct 27: 1 to look at"
    assert List.last(lines) == "• T engine"
  end
end
