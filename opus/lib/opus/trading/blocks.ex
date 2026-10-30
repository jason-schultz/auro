defmodule Opus.Trading.Blocks do
  @moduledoc """
  The signal blocks a strategy is built from, explained for someone who
  isn't a trader: which question each one answers (`group`), what it
  watches in one sentence, what each setting does, and what to draw so the
  builder's preview can show the indicator itself.

  Everything about a block except its group comes from the engine's block
  catalog (`auro_be/src/engine/catalog.rs`), generated into
  `priv/block_catalog.json` and read here at compile time, so the builder
  and the plain-words rules (`Opus.Trading.StrategyWords`) work while the
  engine is down. A new block shows up after its JSON is regenerated and
  its type is added to a group below (or to `@hidden`).

  `draw` lists the values the engine reports for the block
  (`Signaler::series`): `place: :price` draws a line on the candles;
  `place: :panel` draws its own small chart underneath, with `levels`
  (a setting's key, or a fixed number) as dashed reference lines and an
  optional fixed `range`.
  """

  @catalog_path Path.expand("../../../priv/block_catalog.json", __DIR__)
  @external_resource @catalog_path

  # The builder's groups, in order: `{name, question, block types}`.
  @groups [
    {"Trend", "Is it going up or down?", ~w(MaFilter TrendFollowing AdxFilter)},
    {"Stretch", "Has it gone too far, too fast?",
     ~w(RsiReversion MeanReversion Bollinger Stochastic)},
    {"Breakout", "Is it escaping its usual range?", ~w(Donchian NoiseArea OpeningRange)},
    {"Momentum", "Is it speeding up or slowing down?", ~w(Macd Momentum)},
    {"Volatility", "Is the market calm or wild?", ~w(Volatility)},
    {"Levels", "Where is the price against key prices?", ~w(Vwap PivotPoints)},
    {"Carry", "Does holding it pay interest?", ~w(Carry)}
  ]

  # Blocks the builder doesn't offer: Opus fills their settings itself
  # (EventWindow's event times come from the macro calendar).
  @hidden ~w(EventWindow)

  @group_of for {name, _question, types} <- @groups, type <- types, into: %{}, do: {type, name}

  @catalog (for b <- Jason.decode!(File.read!(@catalog_path))["blocks"] do
              %{
                type: b["type"],
                name: b["name"],
                group: @group_of[b["type"]],
                key: b["key"],
                watches: b["watches"],
                params:
                  Enum.map(b["settings"], fn s ->
                    %{
                      key: s["key"],
                      label: s["label"],
                      kind:
                        case s["kind"] do
                          "option" ->
                            {:select, Enum.map(s["options"], &{&1["label"], &1["value"]})}

                          kind ->
                            String.to_atom(kind)
                        end,
                      default: s["default"],
                      help: s["help"],
                      reads: s["reads"]
                    }
                  end),
                ports: Enum.map(b["ports"], & &1["key"]),
                words: Map.new(b["ports"], &{&1["key"], &1["words"]}),
                stop: b["stop"],
                draw:
                  Enum.map(b["series"], fn s ->
                    line = %{key: s["key"], label: s["label"], place: String.to_atom(s["place"])}

                    if s["place"] == "panel" do
                      levels =
                        Enum.map(s["levels"], fn
                          %{"neg" => key} -> {:neg, key}
                          level -> level
                        end)

                      Map.merge(
                        line,
                        Map.reject(
                          %{
                            levels: levels,
                            range: s["range"] && List.to_tuple(s["range"]),
                            with: s["with"]
                          },
                          fn {_k, v} -> is_nil(v) end
                        )
                      )
                    else
                      line
                    end
                  end)
              }
            end)

  @blocks for {_name, _question, types} <- @groups,
              type <- types,
              block = Enum.find(@catalog, &(&1.type == type)),
              block != nil,
              do: block

  @doc "The question groups, in order: `[{name, question}]`."
  @spec groups() :: [{String.t(), String.t()}]
  def groups, do: for({name, question, _types} <- @groups, do: {name, question})

  @doc "Every block the builder offers, in group order."
  @spec all() :: [map()]
  def all, do: @blocks

  @doc "Every block the engine knows, the builder's and `hidden/0` ones."
  @spec catalog() :: [map()]
  def catalog, do: @catalog

  @doc "Block types the builder doesn't offer."
  @spec hidden() :: [String.t()]
  def hidden, do: @hidden

  @doc "The blocks of each group: `[{name, question, blocks}]`."
  @spec by_group() :: [{String.t(), String.t(), [map()]}]
  def by_group,
    do:
      for(
        {name, question, _types} <- @groups,
        do: {name, question, Enum.filter(@blocks, &(&1.group == name))}
      )

  @doc "The builder's block for a component type, or nil."
  @spec get(String.t()) :: map() | nil
  def get(type), do: Enum.find(@blocks, &(&1.type == type))

  @doc "Any block the engine knows for a component type, hidden ones too, or nil."
  @spec any(String.t()) :: map() | nil
  def any(type), do: Enum.find(@catalog, &(&1.type == type))

  @doc """
  A draw spec's reference lines for a component's settings: setting keys
  become their values, `{:neg, key}` the negated value, numbers stay.
  """
  @spec levels(map(), map()) :: [float()]
  def levels(%{levels: levels}, params) do
    Enum.flat_map(levels, fn
      n when is_number(n) -> [n / 1]
      {:neg, key} -> number(params[key]) |> List.wrap() |> Enum.map(&(-&1))
      key -> number(params[key]) |> List.wrap()
    end)
  end

  def levels(_spec, _params), do: []

  defp number(n) when is_number(n), do: n / 1

  defp number(text) when is_binary(text) do
    case Float.parse(text) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(_), do: nil
end
