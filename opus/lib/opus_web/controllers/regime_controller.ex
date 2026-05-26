defmodule OpusWeb.RegimeController do
  use OpusWeb, :controller

  @moduledoc """
  Regime API endpoints.

  Heatmap output is dual-frame aware: columns are derived from currently enabled
  strategy entry granularities via Granularity.regime_frames_for_entry/1.
  Cells include an `applicable` flag so the frontend can render "n/a" for
  frames that are not used by an instrument's enabled strategies.
  """

  alias Opus.Trading.RegimeDetector
  alias Opus.Repo
  alias Opus.Trading.Granularity

  import Ecto.Query

  def index(conn, _params) do
    regimes =
      RegimeDetector.get_all_regimes()
      |> Enum.map(fn {{instrument, granularity}, data} ->
        Map.merge(data, %{instrument: instrument, granularity: granularity})
      end)

    json(conn, %{count: length(regimes), regimes: regimes})
  end

  def heatmap(conn, _params) do
    enabled_targets =
      from(s in "live_strategies",
        where: s.enabled == true,
        distinct: [s.instrument, s.granularity],
        select: {s.instrument, s.granularity}
      )
      |> Repo.all()

    {enabled_instruments, granularities, instrument_frames} =
      prepare_heatmap_targets(enabled_targets)

    regime_map = RegimeDetector.get_all_regimes()

    rows =
      Enum.map(enabled_instruments, fn instrument ->
        cells =
          Enum.map(granularities, fn granularity ->
            applicable =
              instrument_frames
              |> Map.get(instrument, MapSet.new())
              |> MapSet.member?(granularity)

            data = Map.get(regime_map, {instrument, granularity}, %{})

            %{
              granularity: granularity,
              applicable: applicable,
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
      granularities: granularities,
      rows: rows,
      count: length(rows)
    })
  end

  defp normalize_regime(nil), do: "unknown"
  defp normalize_regime(regime) when is_atom(regime), do: Atom.to_string(regime)
  defp normalize_regime(regime), do: regime

  defp prepare_heatmap_targets(enabled_targets) do
    {instruments, frame_set, instrument_frames} =
      Enum.reduce(enabled_targets, {MapSet.new(), MapSet.new(), %{}}, fn {instrument,
                                                                          entry_granularity},
                                                                         {instruments_acc,
                                                                          frames_acc,
                                                                          by_inst_acc} ->
        required = MapSet.new(Granularity.regime_frames_for_entry(entry_granularity))

        {
          MapSet.put(instruments_acc, instrument),
          MapSet.union(frames_acc, required),
          Map.update(by_inst_acc, instrument, required, &MapSet.union(&1, required))
        }
      end)

    {
      instruments |> MapSet.to_list() |> Enum.sort(),
      frame_set |> MapSet.to_list() |> sort_granularities(),
      instrument_frames
    }
  end

  defp sort_granularities(frames) do
    order =
      Granularity.all()
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(frames, &Map.get(order, &1, 999))
  end
end
