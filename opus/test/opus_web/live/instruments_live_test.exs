defmodule OpusWeb.InstrumentsLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Opus.Instruments

  test "lists the master with its vendor spellings", %{conn: conn} do
    {:ok, ry} = Instruments.add("RY.TO", "equity")

    {:ok, _view, html} = live(conn, ~p"/instruments")

    assert html =~ "Instruments"
    assert html =~ ~s(id="instrument-#{ry.id}")
    assert html =~ "Questrade RY.TO"
    assert html =~ "TSX · CAD · equity"
    assert html =~ "listings shown"
  end

  test "adds a listing from its spelling", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/instruments")

    html =
      view
      |> form("#add-form", listing: %{"spelling" => "xiu.to", "asset_class" => "etf"})
      |> render_submit()

    assert html =~ "Added TSX:XIU."
    assert [%{symbol: "XIU", asset_class: "etf"}] = Instruments.list()
  end

  test "ticking a feed flags the listing for that feed", %{conn: conn} do
    {:ok, spy} = Instruments.add("SPY", "etf")
    {:ok, view, _html} = live(conn, ~p"/instruments")

    assert Instruments.feed_symbols(:options_chain) == []

    view
    |> element("#instrument-#{spy.id} input[phx-value-flag=feed_options_chain]")
    |> render_click()

    assert Instruments.feed_symbols(:options_chain) == ["SPY"]

    view |> element("#instrument-#{spy.id} input[phx-value-flag=active]") |> render_click()
    assert Instruments.feed_symbols(:options_chain) == []
  end

  test "search and the market chips narrow the table", %{conn: conn} do
    {:ok, ry} = Instruments.add("RY.TO", "equity")
    {:ok, eur} = Instruments.add("EUR_USD", "fx_major")
    {:ok, spy} = Instruments.add("SPY", "etf")
    {:ok, view, _html} = live(conn, ~p"/instruments")

    html = view |> form("#search-form", search: "eur") |> render_change()
    assert html =~ ~s(id="instrument-#{eur.id}")
    refute html =~ ~s(id="instrument-#{ry.id}")

    view |> form("#search-form", search: "") |> render_change()
    html = view |> element("button", "Canada") |> render_click()
    assert html =~ ~s(id="instrument-#{ry.id}")
    refute html =~ ~s(id="instrument-#{spy.id}")
    refute html =~ ~s(id="instrument-#{eur.id}")
  end

  test "retired listings hide until asked for", %{conn: conn} do
    {:ok, ry} = Instruments.add("RY.TO", "equity")
    {:ok, _} = Instruments.toggle(ry, :active)
    {:ok, view, html} = live(conn, ~p"/instruments")

    refute html =~ ~s(id="instrument-#{ry.id}")
    assert html =~ "Nothing matches."

    html = view |> element("input[phx-click=inactive]") |> render_click()
    assert html =~ ~s(id="instrument-#{ry.id}")
  end

  # config/test.exs points the Auro client at a closed port.
  test "identifying via Questrade reports that Auro is unreachable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/instruments")

    html = view |> element("button", "Identify via Questrade") |> render_click()
    assert html =~ "Auro is not running."
  end
end
