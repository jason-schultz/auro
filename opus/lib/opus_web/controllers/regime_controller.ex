defmodule OpusWeb.RegimeController do
  use OpusWeb, :controller

  alias Opus.Trading.RegimeDetector
  alias Opus.Repo

  import Ecto.Query

  @heatmap_granularities ~w[D H4 H1 M15]

  def index(conn, _params) do
    regimes =
      RegimeDetector.get_all_regimes()
      |> Enum.map(fn {{instrument, granularity}, data} ->
        Map.merge(data, %{instrument: instrument, granularity: granularity})
      end)

    json(conn, %{count: length(regimes), regimes: regimes})
  end

  def heatmap(conn, _params) do
    enabled_instruments =
      from(s in "live_strategies",
        where: s.enabled == true,
        distinct: true,
        select: s.instrument
      )
      |> Repo.all()
      |> Enum.sort()

    regime_map = RegimeDetector.get_all_regimes()

    rows =
      Enum.map(enabled_instruments, fn instrument ->
        cells =
          Enum.map(@heatmap_granularities, fn granularity ->
            data = Map.get(regime_map, {instrument, granularity}, %{})

            %{
              granularity: granularity,
              regime: normalize_regime(data[:regime]),
              adx: data[:adx],
              bandwidth_pct: data[:bandwidth_pct],
              last_close_time: data[:last_close_time]
            }
          end)

        %{instrument: instrument, cells: cells}
      end)

    json(conn, %{
      instruments: enabled_instruments,
      granularities: @heatmap_granularities,
      rows: rows,
      count: length(rows)
    })
  end

  defp normalize_regime(nil), do: "unknown"
  defp normalize_regime(regime) when is_atom(regime), do: Atom.to_string(regime)
  defp normalize_regime(regime), do: regime
end
