defmodule OpusWeb.CopyTest do
  use ExUnit.Case, async: true

  import OpusWeb.Copy

  test "a label carries its serious wording and its WSB twin" do
    assert copy("Overview") == %{s: "Overview", wsb: "The whole degenerate book"}
  end

  test "slots are filled in both voices" do
    assert copy("Test results on %{instrument}", instrument: "SPX500_USD") ==
             %{s: "Test results on SPX500_USD", wsb: "Receipts on SPX500_USD"}
  end

  test "a label with no WSB twin shows its serious wording in both" do
    assert copy("ADX 14") == %{s: "ADX 14", wsb: "ADX 14"}
  end

  test "a language with no WSB wording falls back to that language's serious wording" do
    Gettext.with_locale(OpusWeb.Gettext, "fr", fn ->
      %{s: s, wsb: wsb} = copy("Overview")
      assert wsb == s
    end)
  end

  test "counted labels pick the singular or plural in both voices" do
    one = copy_n("%{count} thing needs you", "%{count} things need you", 1)
    many = copy_n("%{count} thing needs you", "%{count} things need you", 3)

    assert one == %{s: "1 thing needs you", wsb: "1 thing needs you, regard"}
    assert many == %{s: "3 things need you", wsb: "3 things need you, regard"}
  end

  test "the same serious wording can carry a different twin per context" do
    assert copy("Ideas").wsb == "Plays"
    assert pcopy("paper book", "Ideas") == %{s: "Ideas", wsb: "Dip YOLOs"}
  end
end
