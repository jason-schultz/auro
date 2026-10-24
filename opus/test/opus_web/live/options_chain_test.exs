defmodule OpusWeb.OptionsChainTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Options
  alias Opus.Repo

  @expiry ~D[2026-12-18]

  setup do
    Repo.delete_all("option_quotes")
    Repo.delete_all("option_contracts")
    {:ok, spy} = Instruments.add("SPY", "etf")
    now = ~N[2026-10-24 02:00:03]
    stale = ~N[2026-10-23 02:00:03]

    contracts =
      for {kind, strike} <- [{"put", 755.0}, {"put", 760.0}, {"put", 765.0}, {"call", 765.0}] do
        %{
          ticker: "O:SPY261218#{String.upcase(String.first(kind))}#{trunc(strike)}",
          underlying: "SPY",
          contract_type: kind,
          expiration_date: @expiry,
          strike: strike,
          first_seen_at: now,
          last_seen_at: now,
          underlying_instrument_id: spy.id
        }
      end

    {_, rows} =
      Repo.insert_all("option_contracts", contracts, returning: [:id, :strike, :contract_type])

    quotes =
      for %{id: id, strike: strike} <- rows,
          captured <- [stale, now] do
        %{
          ticker: "x",
          captured_at: captured,
          source: "questrade",
          spot: 761.11,
          bid: strike / 100,
          ask: strike / 100 + 0.1,
          volatility: 18.5,
          delta: -0.4,
          open_interest: 100,
          contract_id: id
        }
      end

    Repo.insert_all("option_quotes", quotes)
    :ok
  end

  test "the context reads the latest snapshot only" do
    assert [%{symbol: "SPY", captured_at: ~N[2026-10-24 02:00:03.000000]}] = Options.underlyings()
    assert Options.expiries("SPY") == [@expiry]

    puts = Options.chain("SPY", @expiry, "put")
    assert Enum.map(puts, & &1.strike) == [755.0, 760.0, 765.0]
    assert Enum.all?(puts, &(&1.captured_at == ~N[2026-10-24 02:00:03.000000]))
    assert [%{strike: 765.0}] = Options.chain("SPY", @expiry, "call")
    assert Options.chain("SPY", ~D[2027-01-15], "put") == []
  end

  test "picking a strike fills the position from the quote and runs the analysis", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/options")

    assert html =~ "· SPY puts"
    assert html =~ "Dec 18"
    assert html =~ "at the money"

    html = view |> element("button[phx-value-strike='755']") |> render_click()

    # Selling a put takes the bid; the quote's volatility and spot come along.
    assert html =~ ~s(value="755")
    assert html =~ ~s(value="7.55")
    assert html =~ ~s(value="761.11")
    assert html =~ ~s(value="18.5")
    assert html =~ ~s(value="2026-12-18")
    assert html =~ "Auro is not running."
  end

  test "switching to a call strategy shows the calls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")

    html =
      view
      |> form("#position-form", position: %{"strategy" => "long_call"})
      |> render_change()

    assert html =~ "· SPY calls"
    assert html =~ "phx-value-strike=\"765\""
    refute html =~ "phx-value-strike=\"755\""
  end
end
