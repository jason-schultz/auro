defmodule OpusWeb.RegimeController do
  use OpusWeb, :controller

  alias Opus.Trading.RegimeDetector

  def index(conn, _params) do
    regimes =
      RegimeDetector.get_all_regimes()
      |> Enum.map(fn {{instrument, granularity}, data} ->
        Map.merge(data, %{instrument: instrument, granularity: granularity})
      end)

    json(conn, %{count: length(regimes), regimes: regimes})
  end
end
