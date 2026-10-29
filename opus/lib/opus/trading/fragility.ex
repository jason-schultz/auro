defmodule Opus.Trading.Fragility do
  @moduledoc """
  "Is it fragile?": re-run a strategy at settings near its own and see
  whether the result holds up. A sturdy strategy passes across a
  neighbourhood of settings; a lucky one passes only at its exact numbers.

  Pure: picks the settings that can be varied (`axes/1`), the nearby values
  to try (`values/1`), and reads the engine's grid
  (`Opus.Auro.Client.strategy_sensitivity/3`) into rows and a verdict in
  plain words (`shape/3`).
  """

  alias Opus.Trading.Blocks

  # How far either side of the current setting to look.
  @steps [0.5, 0.75, 1.0, 1.25, 1.5]

  @type axis :: %{
          id: String.t(),
          component: String.t(),
          param: String.t(),
          label: String.t(),
          kind: :int | :float,
          value: number()
        }

  @doc """
  Every numeric setting of the strategy's blocks, in block-name order:
  what the "Is it fragile?" pickers offer. Each has an `id`
  (`"r.oversold"`) and a label like `"RSI · Oversold below"`.
  """
  @spec axes(map()) :: [axis()]
  def axes(definition) do
    for {name, %{"type" => type} = c} <- Enum.sort(definition["components"] || %{}),
        %{params: params, name: block} <- [Blocks.get(type)],
        %{kind: kind} = p when kind in [:int, :float] <- params,
        value = (c["params"] || %{})[p.key],
        is_number(value) do
      %{
        id: "#{name}.#{p.key}",
        component: name,
        param: p.key,
        label: "#{block} · #{p.label}",
        kind: kind,
        value: value
      }
    end
  end

  @doc "The two settings to vary first: the first two, or one when there's only one."
  @spec default_pair([axis()]) :: {axis() | nil, axis() | nil}
  def default_pair([x, y | _]), do: {x, y}
  def default_pair([x]), do: {x, nil}
  def default_pair([]), do: {nil, nil}

  @doc """
  Values around a setting: half, three quarters, itself, one and a quarter
  and one and a half times it. Bar counts stay whole and at least 1, so a
  small one (2) gives fewer, distinct values.
  """
  @spec values(axis()) :: [number()]
  def values(%{kind: :int, value: v}) do
    @steps |> Enum.map(&max(round(v * &1), 1)) |> Enum.uniq()
  end

  def values(%{value: v}) do
    @steps |> Enum.map(&Float.round(v * &1 / 1, 2)) |> Enum.uniq()
  end

  @doc """
  The grid as rows (the y values, largest first, so up means more) of
  cells `%{x, y, total_return, num_trades, t_stat, passed, error, current}`,
  plus a verdict in plain words.
  """
  @spec shape([map()], axis(), axis() | nil) :: map()
  def shape(cells, x, y) do
    cells = Enum.map(cells, &cell(&1, x, y))
    ok = Enum.reject(cells, & &1.error)
    passed = Enum.count(ok, & &1.passed)
    current = Enum.find(cells, & &1.current)

    rows =
      cells
      |> Enum.group_by(& &1.y)
      |> Enum.sort_by(fn {y, _} -> y || 0 end, :desc)
      |> Enum.map(fn {y, row} -> %{y: y, cells: Enum.sort_by(row, & &1.x)} end)

    %{
      rows: rows,
      xs: cells |> Enum.map(& &1.x) |> Enum.uniq() |> Enum.sort(),
      passed: passed,
      total: length(ok),
      verdict: verdict(passed, length(ok), current)
    }
  end

  defp cell(c, x, y) do
    %{
      x: c["x"],
      y: c["y"],
      total_return: c["total_return"],
      num_trades: c["num_trades"],
      t_stat: c["t_stat"],
      passed: c["passed"] == true,
      error: c["error"],
      current: same?(c["x"], x.value) and (is_nil(y) or same?(c["y"], y.value))
    }
  end

  defp same?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-9
  defp same?(_, _), do: false

  defp verdict(_passed, 0, _current),
    do: %{tone: :none, words: "None of the nearby settings could be tested."}

  defp verdict(passed, total, current) do
    share = passed / total
    of = "#{passed} of #{total} nearby settings"

    cond do
      current && !current.passed ->
        %{
          tone: :weak,
          words:
            "These exact settings don't pass the backtest standard; #{of} do. " <>
              "Look for a setting in the middle of a green patch."
        }

      share >= 0.6 ->
        %{
          tone: :sturdy,
          words: "Sturdy: #{of} also pass. The result doesn't hinge on these exact numbers."
        }

      share >= 0.3 ->
        %{
          tone: :mixed,
          words: "Mixed: #{of} pass. It works in a patch of settings, not everywhere."
        }

      true ->
        %{
          tone: :fragile,
          words: "Fragile: only #{of} pass. The result may be luck from these exact numbers."
        }
    end
  end
end
