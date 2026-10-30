defmodule OpusWeb.AccountsLiveTest do
  # Not async: the Questrade tests point the engine's address at a stand-in.
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # config/test.exs points the Auro client at a closed port, so the page
  # exercises its unreachable-engine state end to end.
  test "renders the frame, then reports that Auro is unreachable once connected", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/accounts")

    assert html =~ "Accounts"
    assert html =~ "Auro"
    assert render_async(view) =~ "Auro is not running."
  end

  test "refresh re-queries the engine and surfaces the same failure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/accounts")

    render_async(view)
    view |> element("button", "Refresh") |> render_click()
    assert render_async(view) =~ "Auro is not running."
  end

  describe "reconnecting Questrade" do
    # A stand-in engine: Questrade starts offline; `connect` is how the
    # engine answers POST /api/questrade/connect. Every token it receives
    # is sent to the test process.
    defmodule Engine do
      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(%Plug.Conn{request_path: "/api/brokers"} = conn, %{state: state}) do
        connected = Agent.get(state, & &1)

        json(conn, 200, [
          %{
            "broker" => "questrade",
            "display_name" => "Questrade",
            "connected" => connected,
            "error" => if(connected, do: nil, else: "Questrade auth error (400): Bad Request"),
            "accounts" => []
          }
        ])
      end

      def call(%Plug.Conn{request_path: "/api/brokers/wealthsimple"} = conn, _opts),
        do: json(conn, 200, [])

      def call(%Plug.Conn{request_path: "/api/questrade/connect"} = conn, opts) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(opts.test, {:token_sent, Jason.decode!(body)["refresh_token"]})
        {status, answer} = opts.connect
        if status == 200, do: Agent.update(opts.state, fn _ -> true end)
        json(conn, status, answer)
      end

      def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

      defp json(conn, status, body) do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end

    defp engine(connect_answer) do
      state = start_supervised!({Agent, fn -> false end})

      pid =
        start_supervised!(
          {Bandit,
           plug: {Engine, %{state: state, connect: connect_answer, test: self()}},
           port: 0,
           ip: :loopback,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      previous = Application.fetch_env!(:opus, :auro_base_url)
      on_exit(fn -> Application.put_env(:opus, :auro_base_url, previous) end)
      Application.put_env(:opus, :auro_base_url, "http://127.0.0.1:#{port}")
    end

    defp submit(view, token) do
      view
      |> form("#questrade-connect", %{"questrade_token" => token})
      |> render_submit()

      # The connect, then the overview it reloads on success.
      render_async(view)
      render_async(view)
    end

    test "offline Questrade offers the token form with where to get one", %{conn: conn} do
      engine({200, %{"connected" => true, "accounts" => []}})
      {:ok, view, _html} = live(conn, ~p"/accounts")

      html = render_async(view)
      assert html =~ "Paste a new Questrade token"
      assert html =~ "API centre"
      assert has_element?(view, ~s(#questrade-connect input[type="password"]))
    end

    test "a pasted token connects Questrade and the form goes away", %{conn: conn} do
      engine({200, %{"connected" => true, "accounts" => []}})
      {:ok, view, _html} = live(conn, ~p"/accounts")
      render_async(view)

      html = submit(view, "  secret-token-123  ")

      assert_received {:token_sent, "secret-token-123"}
      assert html =~ "Questrade is connected again."
      refute html =~ "Paste a new Questrade token"
      refute html =~ "secret-token-123"
    end

    test "a refused token says why and keeps the form", %{conn: conn} do
      engine(
        {502,
         %{
           "connected" => false,
           "error" => "Questrade auth error (400 Bad Request): Bad Request"
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/accounts")
      render_async(view)

      html = submit(view, "secret-token-456")

      assert_received {:token_sent, "secret-token-456"}
      assert html =~ "That didn&#39;t connect"
      assert html =~ "Questrade auth error (400 Bad Request)"
      assert html =~ "Paste a new Questrade token"
      refute html =~ "secret-token-456"
    end

    test "a blank token never reaches the engine", %{conn: conn} do
      engine({200, %{"connected" => true, "accounts" => []}})
      {:ok, view, _html} = live(conn, ~p"/accounts")
      render_async(view)

      assert submit(view, "   ") =~ "Paste the token from Questrade first."
      refute_received {:token_sent, _}
    end

    test "Phoenix keeps the token out of its event logs" do
      assert Phoenix.Logger.filter_values(%{"questrade_token" => "secret"}) ==
               %{"questrade_token" => "[FILTERED]"}
    end
  end
end
