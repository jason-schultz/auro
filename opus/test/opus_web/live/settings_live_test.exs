defmodule OpusWeb.SettingsLiveTest do
  # Not async: tests point the engine's address at a stand-in.
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Settings

  # A stand-in engine. Its state: the statuses `GET /api/settings/status`
  # answers, what `POST /api/settings/apply` answers per connection, and
  # whether Questrade is connected. Every apply and token it receives is
  # sent to the test process.
  defmodule Engine do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{request_path: "/api/settings/status"} = conn, %{state: state}),
      do: json(conn, 200, Agent.get(state, & &1.statuses))

    def call(%Plug.Conn{request_path: "/api/settings/apply"} = conn, %{state: state, test: test}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      connection = Jason.decode!(body)["connection"]
      send(test, {:applied, connection})
      status = Agent.get(state, & &1.apply[connection])
      Agent.update(state, &put_in(&1, [:statuses, connection], status))
      json(conn, 200, %{"connection" => connection, "status" => status})
    end

    def call(%Plug.Conn{request_path: "/api/brokers"} = conn, %{state: state}) do
      connected = Agent.get(state, & &1.questrade)

      json(conn, 200, [
        %{
          "broker" => "questrade",
          "connected" => connected,
          "error" => if(connected, do: nil, else: "Questrade auth error (400): Bad Request"),
          "accounts" => []
        }
      ])
    end

    def call(%Plug.Conn{request_path: "/api/questrade/connect"} = conn, %{state: state} = opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts.test, {:token_sent, Jason.decode!(body)["refresh_token"]})
      {status, answer} = Agent.get(state, & &1.connect)
      if status == 200, do: Agent.update(state, &Map.put(&1, :questrade, true))
      json(conn, status, answer)
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  @in_use %{"in_use_since" => "2026-11-01T22:35:00Z", "ok" => true}

  defp engine(overrides \\ %{}) do
    initial =
      Map.merge(
        %{
          statuses: %{"oanda" => @in_use, "massive" => @in_use},
          apply: %{
            "oanda" => Map.put(@in_use, "words", "OANDA answered for account 101-9 (CAD)."),
            "massive" => Map.put(@in_use, "words", "Massive answered with this key.")
          },
          questrade: false,
          connect: {200, %{"connected" => true, "accounts" => []}}
        },
        overrides
      )

    state = start_supervised!({Agent, fn -> initial end})

    pid =
      start_supervised!(
        {Bandit,
         plug: {Engine, %{state: state, test: self()}}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.fetch_env!(:opus, :auro_base_url)
    on_exit(fn -> Application.put_env(:opus, :auro_base_url, previous) end)
    Application.put_env(:opus, :auro_base_url, "http://127.0.0.1:#{port}")
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    # The engine's statuses, then Questrade's.
    render_async(view)
    {view, render_async(view)}
  end

  describe "the integrations page" do
    test "groups the tiles, with placeholders and no Wealthsimple", %{conn: conn} do
      engine(%{questrade: true})
      {view, html} = open(conn, ~p"/settings")

      for group <- ["Brokers", "Market data", "AI", "Notifications"], do: assert(html =~ group)
      assert has_element?(view, "#tile-oanda-practice", "In use")
      assert has_element?(view, "#tile-oanda-real", "Not set up")
      assert html =~ "Interactive Brokers"
      assert html =~ "Coming later"
      refute html =~ "Wealthsimple"
      refute has_element?(view, "#needs-attention")
    end

    test "a problem shows under Needs attention and links to its panel", %{conn: conn} do
      engine(%{
        statuses: %{
          "oanda" => @in_use,
          "massive" => %{"ok" => false, "words" => "Massive refused it (401)."}
        }
      })

      {view, _html} = open(conn, ~p"/settings/integrations")

      assert has_element?(view, "#needs-attention", "Massive refused it (401).")
      assert has_element?(view, "#tile-massive", "Problem")

      view |> element("#needs-attention a", "Open Massive") |> render_click()
      assert_patch(view, ~p"/settings/integrations/massive")
      assert has_element?(view, "#panel-massive")
    end

    test "the engine being down says so instead of a guess", %{conn: conn} do
      # config/test.exs points the engine at a closed port.
      {view, _html} = open(conn, ~p"/settings")
      assert has_element?(view, "#tile-oanda-practice", "Unknown")
    end
  end

  describe "a panel" do
    test "opens at its own address and closes back to the grid", %{conn: conn} do
      engine()
      {view, html} = open(conn, ~p"/settings/integrations/oanda-practice")

      assert html =~ "Prices from: OANDA Practice"
      assert html =~ "In use since"

      view |> element("#panel-oanda-practice a[aria-label=Close]") |> render_click()
      assert_patch(view, ~p"/settings/integrations")
      refute has_element?(view, "#panel-oanda-practice")
    end

    test "a placeholder has no panel", %{conn: conn} do
      engine()

      assert {:error, {:live_redirect, %{to: "/settings/integrations"}}} =
               live(conn, ~p"/settings/integrations/alpaca")
    end

    test "saving keeps an empty secret, then the engine checks and applies it", %{conn: conn} do
      engine()
      :ok = Settings.put("OANDA_API_KEY", "first-key-0001")
      {view, html} = open(conn, ~p"/settings/integrations/oanda-practice")
      assert html =~ "ends …0001"
      refute html =~ "first-key"

      view
      |> form("#settings-oanda-practice-form", %{
        "fields" => %{"OANDA_API_KEY" => "", "OANDA_ACCOUNT_ID" => "101-9"}
      })
      |> render_submit()

      assert_receive {:applied, "oanda"}
      assert render_async(view) =~ "OANDA answered for account 101-9 (CAD)."
      assert Settings.get("OANDA_API_KEY") == "first-key-0001"
      assert Settings.get("OANDA_ACCOUNT_ID") == "101-9"
    end

    test "a refused key shows as a problem and the old one stays in use", %{conn: conn} do
      refused = %{
        "in_use_since" => "2026-11-01T22:35:00Z",
        "ok" => false,
        "words" => "Massive refused it (401). Still using the previous key."
      }

      engine(%{apply: %{"massive" => refused}})
      {view, _html} = open(conn, ~p"/settings/integrations/massive")

      view
      |> form("#settings-massive-form", %{"fields" => %{"MASSIVE_API_KEY" => "typo"}})
      |> render_submit()

      assert_receive {:applied, "massive"}
      render_async(view)
      assert has_element?(view, "#panel-massive", "Still using the previous key")
      assert has_element?(view, "#needs-attention", "Massive")
    end

    test "saving with the engine down keeps the value for its next start", %{conn: conn} do
      {view, _html} = open(conn, ~p"/settings/integrations/massive")

      view
      |> form("#settings-massive-form", %{"fields" => %{"MASSIVE_CALLS_PER_MINUTE" => "5"}})
      |> render_submit()

      assert render_async(view) =~ "It reads the saved values when it starts."
      assert Settings.get("MASSIVE_CALLS_PER_MINUTE") == "5"
    end

    test "Remove takes a saved value away and rechecks", %{conn: conn} do
      engine()
      :ok = Settings.put("MASSIVE_CALLS_PER_MINUTE", "5")
      {view, _html} = open(conn, ~p"/settings/integrations/massive")

      view
      |> element(~s(#panel-massive button[phx-value-name="MASSIVE_CALLS_PER_MINUTE"]))
      |> render_click()

      assert_receive {:applied, "massive"}
      assert Settings.get("MASSIVE_CALLS_PER_MINUTE") == nil
    end
  end

  describe "Questrade" do
    defp submit(view, token) do
      view |> form("#questrade-connect", %{"questrade_token" => token}) |> render_submit()
      # The connect, then the status it asks for again on success.
      render_async(view)
      render_async(view)
    end

    test "shows that it's offline and where to get a token", %{conn: conn} do
      engine()
      {view, html} = open(conn, ~p"/settings/integrations/questrade")

      assert html =~ "Not connected: Questrade auth error (400): Bad Request"
      assert html =~ "API centre"
      assert has_element?(view, ~s(#questrade-connect input[type="password"]))
    end

    test "a pasted token connects it", %{conn: conn} do
      engine()
      {view, _html} = open(conn, ~p"/settings/integrations/questrade")

      html = submit(view, "  secret-token-123  ")

      assert_received {:token_sent, "secret-token-123"}
      assert html =~ "Questrade is connected again."
      assert has_element?(view, "#tile-questrade", "Connected")
      refute html =~ "secret-token-123"
    end

    test "a refused token says why", %{conn: conn} do
      engine(%{
        connect:
          {502,
           %{
             "connected" => false,
             "error" => "Questrade auth error (400 Bad Request): Bad Request"
           }}
      })

      {view, _html} = open(conn, ~p"/settings/integrations/questrade")
      html = submit(view, "secret-token-456")

      assert_received {:token_sent, "secret-token-456"}
      assert html =~ "That didn&#39;t connect"
      assert html =~ "Questrade auth error (400 Bad Request)"
      refute html =~ "secret-token-456"
    end

    test "a blank token never reaches the engine", %{conn: conn} do
      engine()
      {view, _html} = open(conn, ~p"/settings/integrations/questrade")

      view |> form("#questrade-connect", %{"questrade_token" => "   "}) |> render_submit()
      assert render(view) =~ "Paste the token from Questrade first."
      refute_received {:token_sent, _}
    end

    test "Phoenix keeps the token out of its event logs" do
      assert Phoenix.Logger.filter_values(%{"questrade_token" => "secret"}) ==
               %{"questrade_token" => "[FILTERED]"}
    end
  end

  test "Appearance offers the four themes, and the top bar has no theme switch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    for theme <- ~w(system light dark wsb),
        do: assert(has_element?(view, ~s(#theme-#{theme}[data-phx-theme="#{theme}"])))

    refute has_element?(view, "header [data-phx-theme]")
  end
end
