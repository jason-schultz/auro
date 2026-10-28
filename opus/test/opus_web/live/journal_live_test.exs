defmodule OpusWeb.JournalLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Journal.DigestWorker
  alias Opus.Repo
  alias Opus.Trading.LiveStrategy

  @strategy_id "bbbbbbbb-0000-0000-0000-000000000001"
  @trade_id "cccccccc-0000-0000-0000-000000000001"

  setup do
    Repo.query!("DELETE FROM live_trades")
    Repo.query!("DELETE FROM weekly_digests")
    Repo.delete_all(LiveStrategy)
    :ok
  end

  defp insert_trade do
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: @strategy_id,
      strategy_type: "composite",
      instrument: "NAS100_USD",
      granularity: "M5",
      parameters: %{
        "strategy_name" => "NAS100 noise-area",
        "components" => %{
          "na" => %{"type" => "NoiseArea", "params" => %{"lookback_sessions" => 14}}
        }
      },
      enabled: true,
      curator_mode: "pinned_on",
      created_at: now,
      updated_at: now
    })

    Repo.insert_all("live_trades", [
      %{
        id: Ecto.UUID.dump!(@trade_id),
        live_strategy_id: Ecto.UUID.dump!(@strategy_id),
        oanda_trade_id: "162239",
        instrument: "NAS100_USD",
        direction: "Long",
        units: "1.00",
        status: "closed",
        entry_price: 29_203.6,
        exit_price: 29_312.5,
        entry_time: ~U[2026-10-26 14:30:02Z],
        exit_time: ~U[2026-10-26 20:00:02Z],
        stop_loss_price: 28_873.125,
        pnl: 151.151,
        pnl_percent: 0.003729,
        entry_reason: "Composite Long entry",
        exit_reason: ~s|CompositeExit (ports={"na": {"session_close": true}})|,
        indicators_at_entry: %{"components" => ["na"]},
        mfe_pct: 0.00763,
        mae_pct: 0.0017,
        created_at: now,
        updated_at: now
      }
    ])
  end

  test "renders every review section with an empty book", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal")

    for heading <- ~w(Trades Execution\ quality Holdout\ verdicts Suspended Weekly\ digests) do
      assert html =~ heading
    end

    assert html =~ "First digest lands next Monday."
  end

  test "lists a frozen weekly digest", %{conn: conn} do
    {:ok, digest} = DigestWorker.generate(~D[2026-10-05])
    assert digest.week_end == ~D[2026-10-11]

    {:ok, _view, html} = live(conn, ~p"/journal")

    assert html =~ "2026-10-05"
    refute html =~ "First digest lands next Monday."
  end

  test "lists trades and tells the chosen one in plain words", %{conn: conn} do
    insert_trade()

    # The newest trade is told without picking it.
    {:ok, view, html} = live(conn, ~p"/journal")
    assert html =~ "NAS100 noise-area"
    assert html =~ "End of the trading day"
    assert html =~ "Made $151.15 (+0.37%)"

    html = view |> element(~s|a[href="/journal?trade=#{@trade_id}"]|) |> render_click()
    assert html =~ "Made $151.15 (+0.37%)"
    assert html =~ "broke above its noise area"
    assert html =~ "What to take from it"
    assert html =~ "This strategy has closed 1 live trade."
  end

  test "an unknown trade id falls back to the newest trade", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal?trade=not-a-trade")
    refute html =~ "What to take from it"

    insert_trade()
    {:ok, _view, html} = live(conn, ~p"/journal?trade=not-a-trade")
    assert html =~ "Made $151.15 (+0.37%)"
  end

  test "filters the trades by strategy", %{conn: conn} do
    insert_trade()

    # By URL: the strategy's button only shows while it traded in the last 30 days.
    {:ok, _view, html} = live(conn, ~p"/journal?strategy=#{@strategy_id}")
    assert html =~ "Made $151.15 (+0.37%)"

    {:ok, _view, html} = live(conn, ~p"/journal?strategy=bbbbbbbb-0000-0000-0000-000000000009")
    assert html =~ "No live trades yet."
  end
end
