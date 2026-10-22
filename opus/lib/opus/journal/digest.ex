defmodule Opus.Journal.Digest do
  @moduledoc """
  One week of forward-test numbers, frozen on Monday morning so the trend
  across weeks is visible without re-querying moving windows.

  `payload` holds the Journal's KPIs, per-strategy leaderboard and execution
  quality for the seven days ending Sunday 23:59:59 UTC.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "weekly_digests" do
    field(:week_start, :date, primary_key: true)
    field(:week_end, :date)
    field(:payload, :map)
    field(:generated_at, :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [:week_start, :week_end, :payload, :generated_at])
    |> validate_required([:week_start, :week_end, :payload, :generated_at])
  end

  @type t :: %__MODULE__{
          week_start: Date.t() | nil,
          week_end: Date.t() | nil,
          payload: map() | nil,
          generated_at: DateTime.t() | nil
        }

  @doc "The Monday-to-Sunday week that ended before `at` (UTC)."
  @spec previous_week(DateTime.t()) :: {Date.t(), Date.t()}
  def previous_week(%DateTime{} = at) do
    today = DateTime.to_date(at)
    # Day.of_week: Monday = 1. Back to this week's Monday, then one more week.
    this_monday = Date.add(today, -(Date.day_of_week(today) - 1))
    week_start = Date.add(this_monday, -7)
    {week_start, Date.add(week_start, 6)}
  end
end
