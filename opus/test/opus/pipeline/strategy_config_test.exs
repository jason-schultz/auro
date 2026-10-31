defmodule Opus.Pipeline.StrategyConfigTest do
  # Not async: it adds instruments, whose unique keys other files' tests
  # share; two adding the same ones in parallel can deadlock.
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.StrategyConfig

  @attrs %{
    instrument: "EUR_USD",
    granularity: "H1",
    strategy_type: "composite",
    parameters: %{"instrument" => "EUR_USD"}
  }

  test "a config carries the master id of its instrument" do
    {:ok, eur} = Instruments.add("EUR_USD", "fx_major")

    changeset = StrategyConfig.changeset(%StrategyConfig{}, @attrs)
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :instrument_id) == eur.id
    assert {:ok, %{instrument_id: id}} = Repo.insert(changeset)
    assert id == eur.id
  end

  test "an instrument nobody has added cannot enter the pipeline" do
    changeset = StrategyConfig.changeset(%StrategyConfig{}, @attrs)
    refute changeset.valid?
    assert %{instrument: ["is not in the instruments table"]} = errors_on(changeset)
  end
end
