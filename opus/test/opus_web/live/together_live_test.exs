defmodule OpusWeb.TogetherLiveTest do
  use OpusWeb.ConnCase, async: false

  use Oban.Testing, repo: Opus.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Opus.Instruments

  alias Opus.Pipeline.{
    BacktestWorker,
    HoldoutWorker,
    ParameterStabilityWorker,
    StrategyConfig,
    StrategyEvaluation
  }

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Rule, Suspension}

  # A stand-in engine: answers `path` with 200 and `body`, anything else 404.
  defmodule Engine do
    @behaviour Plug

    @impl true
    def init(answer), do: answer

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, {path, body}) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    def call(conn, _answer), do: Plug.Conn.send_resp(conn, 404, "")
  end

  setup do
    for schema <- [Suspension, Rule, LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    now = DateTime.utc_now()

    recipe =
      Repo.insert!(%Recipe{
        name: "Index dip-buy",
        granularity: "D",
        definition: %{"strategy_name" => "Index dip-buy", "components" => %{}}
      })

    for {instrument, enabled} <- [{"SPX500_USD", true}, {"EU50_EUR", false}] do
      Repo.insert!(%LiveStrategy{
        strategy_type: "composite",
        instrument: instrument,
        granularity: "D",
        parameters: %{"strategy_name" => "Index dip-buy"},
        strategy_id: recipe.id,
        enabled: enabled,
        created_at: now,
        updated_at: now
      })
    end

    :ok
  end

  test "starts the team with the strategies trading now", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/together")

    assert html =~ "Strategies together"
    assert html =~ "1 strategy, all trading now"
    assert html =~ "Run the team to see what it does."

    html = view |> element("button[aria-label*=SPX500_USD]") |> render_click()
    assert html =~ "nobody yet"
  end

  test "the picker adds a strategy that isn't on the team", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/together")

    html = view |> element("button", "Add a strategy") |> render_click()
    assert html =~ "EU50_EUR"

    html = view |> element("li button", "Add") |> render_click()
    assert html =~ "2 strategies, 1 trading now"
  end

  test "says so when the engine can't run them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/together")

    view |> element("button", "See how they do together") |> render_click()
    html = render_async(view, 10_000)

    refute html =~ "Running…"
    # Together runs in the tester (config/test.exs: a closed port).
    assert html =~ "cargo run --release --bin auro-tester"
  end

  describe "from a team to live" do
    setup do
      {:ok, _} = Instruments.add("XAU_USD", "metal")
      :ok
    end

    # A tested play on gold: `stages` passed by today's rules (they record
    # their checks), archived when `archived`.
    defp tested!(name, stages, archived \\ false) do
      config =
        %StrategyConfig{}
        |> StrategyConfig.changeset(%{
          instrument: "XAU_USD",
          granularity: "H4",
          strategy_type: "composite",
          parameters: %{
            "strategy_name" => name,
            "instrument" => "XAU_USD",
            "granularity" => "H4",
            "components" => %{"t" => %{"type" => "Trend", "params" => %{"fast" => 50}}},
            "entry" => %{"long" => "t.up"},
            "exit" => %{"long" => "t.down"},
            "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.03}}
          }
        })
        |> Repo.insert!()

      if archived,
        do:
          Repo.update_all(from(c in StrategyConfig, where: c.id == ^config.id),
            set: [archived_at: DateTime.utc_now()]
          )

      for stage <- stages do
        Repo.insert!(%StrategyEvaluation{
          strategy_config_id: config.id,
          stage: stage,
          status: "passed",
          evaluated_at: DateTime.utc_now(),
          rules_version: StrategyEvaluation.rules_version(),
          stats: %{"checks" => []}
        })
      end

      config
    end

    defp add_to_team(view, config) do
      view |> element("button", "Add a strategy") |> render_click()

      view
      |> element(~s(button[phx-click="add"][phx-value-key="cfg:#{config.id}"]))
      |> render_click()
    end

    test "says how a teammate goes live, and where each strategy stands", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/together")

      assert html =~
               "Strategies that are switched on already trade as one team on your account."

      assert html =~ "On, trading"

      html = view |> element("button", "Add a strategy") |> render_click()
      assert html =~ "Added, switched off"

      html = view |> element("li button", "Add") |> render_click()
      [eu50] = Repo.all(from(s in LiveStrategy, where: s.instrument == "EU50_EUR"))
      assert html =~ ~s(href="/strategies/#{eu50.id}")
      assert html =~ "Open to switch on"
    end

    test "old tests are hidden until asked for", %{conn: conn} do
      tested!("Gold trend", ~w(backtest walk_forward), true)
      {:ok, view, _html} = live(conn, ~p"/together")

      html = view |> element("button", "Add a strategy") |> render_click()
      refute html =~ "Gold trend"

      html = view |> element("button", "Show old tests (1)") |> render_click()
      assert html =~ "Gold trend"
      assert html =~ "Old test (before the current rules): re-test it first"

      html = view |> element("button", "Hide old tests") |> render_click()
      refute html =~ "Gold trend"
    end

    test "an old test on the team is re-tested by today's rules, after a confirm", %{conn: conn} do
      old = tested!("Gold trend", ~w(backtest walk_forward), true)
      {:ok, view, _html} = live(conn, ~p"/together")
      view |> element("button", "Show old tests (1)") |> render_click()
      add_to_team(view, old)

      button = element(view, "button", "Re-test with today's rules")
      assert render(button) =~ "counts as one more try in the luck check"
      refute render(button) =~ "second look"

      html = render_click(button)
      assert html =~ "Re-testing Gold trend · XAU_USD H4 with today&#39;s rules."
      assert html =~ "Still testing (backtest)"

      [new] = Repo.all(from(c in StrategyConfig, where: c.id != ^old.id))
      assert new.parameters == old.parameters
      assert_enqueued(worker: BacktestWorker, args: %{config_id: new.id})
    end

    test "a play stopped part-way is resumed from its stage", %{conn: conn} do
      config = tested!("Gold trend", ~w(backtest walk_forward monte_carlo))
      {:ok, view, _html} = live(conn, ~p"/together")
      html = add_to_team(view, config)
      assert html =~ "Stopped part-way at the nearby-settings test"

      html = view |> element("button", "Resume from nearby-settings test") |> render_click()
      assert html =~ "Resumed from the nearby-settings test."
      assert html =~ "Still testing (nearby-settings test)"
      assert_enqueued(worker: ParameterStabilityWorker, args: %{config_id: config.id})
    end

    test "a play stopped before its holdout resumes only through the confirmed button",
         %{conn: conn} do
      config = tested!("Gold trend", ~w(backtest walk_forward monte_carlo parameter_stability))
      {:ok, view, _html} = live(conn, ~p"/together")
      add_to_team(view, config)

      button = element(view, "button", "Resume from holdout")
      assert render(button) =~ "one-time look at the data kept aside"
      assert render(button) =~ ~s(phx-value-holdout="confirmed")

      # The event without the confirmation takes no look.
      html = render_hook(view, "resume_stage", %{"config" => config.id, "stage" => "holdout"})
      assert html =~ "resume it from its button and confirm"
      refute_enqueued(worker: HoldoutWorker)

      html = render_click(button)
      assert html =~ "Resumed from the holdout."
      assert_enqueued(worker: HoldoutWorker, args: %{config_id: config.id})
    end

    test "re-testing a play already judged on the holdout warns it's a second look", %{conn: conn} do
      old =
        tested!(
          "Gold trend",
          ~w(backtest walk_forward monte_carlo parameter_stability holdout),
          true
        )

      {:ok, view, _html} = live(conn, ~p"/together")
      view |> element("button", "Show old tests (1)") |> render_click()
      add_to_team(view, old)

      button = element(view, "button", "Re-test with today's rules")
      assert render(button) =~ "second look at the same data"
    end

    test "a play that passed every test is added to live, switched off", %{conn: conn} do
      pid =
        start_supervised!(
          {Bandit,
           plug: {Engine, {"/api/live/strategies", %{"enabled" => false}}},
           port: 0,
           ip: :loopback,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      previous = Application.fetch_env!(:opus, :auro_base_url)
      on_exit(fn -> Application.put_env(:opus, :auro_base_url, previous) end)
      Application.put_env(:opus, :auro_base_url, "http://127.0.0.1:#{port}")

      ready =
        tested!("Gold trend", ~w(backtest walk_forward monte_carlo parameter_stability holdout))

      {:ok, view, _html} = live(conn, ~p"/together")
      add_to_team(view, ready)

      assert render(view) =~ "Passed every test: ready to add to live"
      refute render(view) =~ "Re-test with today"

      html = view |> element("button", "Add to live (switched off)") |> render_click()
      assert html =~ "Added Gold trend · XAU_USD H4 to live, switched off."
    end
  end
end
