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

  describe "Questrade offline" do
    # A stand-in engine with Questrade offline.
    defmodule Engine do
      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(%Plug.Conn{request_path: "/api/brokers"} = conn, _opts) do
        json(conn, [
          %{
            "broker" => "questrade",
            "display_name" => "Questrade",
            "connected" => false,
            "error" => "Questrade auth error (400): Bad Request",
            "accounts" => []
          }
        ])
      end

      def call(%Plug.Conn{request_path: "/api/brokers/wealthsimple"} = conn, _opts),
        do: json(conn, [])

      def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

      defp json(conn, body) do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    end

    test "says so and points to Settings to reconnect", %{conn: conn} do
      pid =
        start_supervised!({Bandit, plug: Engine, port: 0, ip: :loopback, startup_log: false})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      previous = Application.fetch_env!(:opus, :auro_base_url)
      on_exit(fn -> Application.put_env(:opus, :auro_base_url, previous) end)
      Application.put_env(:opus, :auro_base_url, "http://127.0.0.1:#{port}")

      {:ok, view, _html} = live(conn, ~p"/accounts")
      html = render_async(view)

      assert html =~ "Questrade is offline"

      assert has_element?(
               view,
               ~s(a[href="/settings/integrations/questrade"]),
               "Reconnect it on Settings"
             )

      refute has_element?(view, "#questrade-connect")
    end
  end
end
