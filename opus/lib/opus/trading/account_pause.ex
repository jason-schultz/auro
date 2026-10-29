defmodule Opus.Trading.AccountPause do
  @moduledoc """
  The account drawdown pause: when NAV falls `drawdown_pause_pct` below its
  peak, every strategy stops opening trades until a person clears the pause.
  Open trades keep their stops and exits.

  The peak is the highest NAV (`account_snapshots`) since the limits took
  effect or the last pause was cleared, so a reset starts from the NAV of
  that moment rather than an older high.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.AccountLimits

  schema "account_pauses" do
    field :triggered_at, :utc_datetime_usec
    field :peak_nav, :float
    field :nav, :float
    field :limit_pct, :float
    field :cleared_at, :utc_datetime_usec
    field :cleared_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The pause in force, if any."
  @spec open() :: %__MODULE__{} | nil
  def open do
    from(p in __MODULE__, where: is_nil(p.cleared_at), order_by: [desc: p.triggered_at], limit: 1)
    |> Repo.one()
  end

  @doc """
  The pause in force, opening one first when NAV has fallen past the limit.
  Nil when trading may continue (or before the limits exist).
  """
  @spec check(DateTime.t()) :: %__MODULE__{} | nil
  def check(now \\ DateTime.utc_now()) do
    with nil <- open(),
         %{drawdown_pause_pct: limit, since: since} <- AccountLimits.get(),
         %{peak: peak, nav: nav} when is_number(peak) <- nav_since(baseline(since)),
         true <- tripped?(peak, nav, limit) do
      Repo.insert!(%__MODULE__{triggered_at: now, peak_nav: peak, nav: nav, limit_pct: limit / 1})
    else
      %__MODULE__{} = pause -> pause
      _ -> nil
    end
  end

  @doc "Whether NAV is `limit_pct` percent or more below `peak`."
  @spec tripped?(number(), number(), number()) :: boolean()
  def tripped?(peak, nav, limit_pct) when peak > 0, do: drawdown(peak, nav) >= limit_pct / 100
  def tripped?(_peak, _nav, _limit_pct), do: false

  @doc "How far `nav` is below `peak`, as a fraction (0.1 = 10% down)."
  @spec drawdown(number(), number()) :: float()
  def drawdown(peak, nav), do: (peak - nav) / peak

  @doc "Clear the pause in force; trading resumes on the next rules push."
  @spec clear(String.t(), DateTime.t()) :: non_neg_integer()
  def clear(by \\ "manual", now \\ DateTime.utc_now()) do
    {count, _} =
      from(p in __MODULE__, where: is_nil(p.cleared_at))
      |> Repo.update_all(set: [cleared_at: now, cleared_by: by, updated_at: now])

    count
  end

  # Peak since the later of the limits taking effect and the last reset.
  defp baseline(since) do
    from(p in __MODULE__, select: max(p.cleared_at))
    |> Repo.one()
    |> case do
      nil -> since
      cleared -> Enum.max([since, cleared], DateTime)
    end
  end

  defp nav_since(since) do
    peak =
      from(s in "account_snapshots", where: s.timestamp >= ^since, select: max(s.nav))
      |> Repo.one()

    nav =
      from(s in "account_snapshots", order_by: [desc: s.timestamp], limit: 1, select: s.nav)
      |> Repo.one()

    %{peak: peak, nav: nav}
  end
end
