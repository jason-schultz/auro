defmodule OpusWeb.InstrumentsLiveTest do
  use OpusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Opus.Instruments

  test "lists the master with its vendor spellings", %{conn: conn} do
    {:ok, ry} = Instruments.add("RY.TO", "equity")

    {:ok, _view, html} = live(conn, ~p"/instruments")

    assert html =~ "Instruments"
    assert html =~ ~s(id="instrument-#{ry.id}")
    assert html =~ "RY.TO"
    assert html =~ "TSX"
    assert html =~ "1 listings"
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

  test "search narrows the table", %{conn: conn} do
    {:ok, ry} = Instruments.add("RY.TO", "equity")
    {:ok, eur} = Instruments.add("EUR_USD", "fx_major")
    {:ok, view, _html} = live(conn, ~p"/instruments")

    html = view |> form("#search-form", search: "eur") |> render_change()
    assert html =~ ~s(id="instrument-#{eur.id}")
    refute html =~ ~s(id="instrument-#{ry.id}")
  end

  # config/test.exs points the Auro client at a closed port.
  test "identifying via Questrade reports that Auro is unreachable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/instruments")

    html = view |> element("button", "Identify via Questrade") |> render_click()
    assert html =~ "Auro is not running."
  end
end
