defmodule Opus.Pipeline.ValidationThreshold do
  @moduledoc """
  Ecto schema and helpers for stage/timeframe validation thresholds.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Opus.Repo

  @primary_key false

  @timeframe_classes ~w[h4 h1 intraday scalp]
  @stages ~w[backtest walk_forward monte_carlo]
  @operators ~w[gte lte gt lt]

  @type t :: %__MODULE__{
          stage: String.t() | nil,
          timeframe_class: String.t() | nil,
          metric: String.t() | nil,
          operator: String.t() | nil,
          value: float() | nil,
          description: String.t() | nil
        }

  schema "validation_thresholds" do
    field(:stage, :string, primary_key: true)
    field(:timeframe_class, :string, primary_key: true)
    field(:metric, :string, primary_key: true)
    field(:operator, :string)
    field(:value, :float)
    field(:description, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(threshold, attrs) do
    threshold
    |> cast(attrs, [:stage, :timeframe_class, :metric, :operator, :value, :description])
    |> validate_required([:stage, :timeframe_class, :metric, :operator, :value])
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:timeframe_class, @timeframe_classes)
    |> validate_inclusion(:operator, @operators)
  end

  @doc "Returns all thresholds for a given stage and timeframe class as a list."
  @spec for_stage_and_class(String.t(), String.t()) :: [t()]
  def for_stage_and_class(stage, timeframe_class) do
    from(t in __MODULE__,
      where: t.stage == ^stage and t.timeframe_class == ^timeframe_class
    )
    |> Repo.all()
  end

  @doc """
  Checks a stats map against all thresholds for the given stage and class.
  Returns :ok or {:error, [failure_reason_strings]}.
  """
  @spec evaluate(map(), String.t(), String.t()) :: :ok | {:error, [String.t()]}
  def evaluate(stats, stage, timeframe_class) do
    thresholds = for_stage_and_class(stage, timeframe_class)

    failures =
      Enum.flat_map(thresholds, fn t ->
        actual = Map.get(stats, t.metric)

        if is_nil(actual) do
          ["#{t.metric}: missing from stats"]
        else
          passes = apply_operator(t.operator, actual, t.value)
          if passes, do: [], else: ["#{t.metric}: #{actual} does not #{t.operator} #{t.value}"]
        end
      end)

    if Enum.empty?(failures), do: :ok, else: {:error, failures}
  end

  defp apply_operator("gte", actual, threshold), do: actual >= threshold
  defp apply_operator("lte", actual, threshold), do: actual <= threshold
  defp apply_operator("gt", actual, threshold), do: actual > threshold
  defp apply_operator("lt", actual, threshold), do: actual < threshold
end
