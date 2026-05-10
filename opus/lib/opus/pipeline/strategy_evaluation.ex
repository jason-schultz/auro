defmodule Opus.Pipeline.StrategyEvaluation do
  @moduledoc """
  Ecto schema for per-stage pipeline evaluation results.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @stages ~w[backtest walk_forward monte_carlo]
  @statuses ~w[pending running passed failed]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          strategy_config_id: Ecto.UUID.t() | nil,
          stage: String.t() | nil,
          status: String.t() | nil,
          stats: map() | nil,
          failure_reason: String.t() | nil,
          evaluated_at: DateTime.t() | nil
        }

  schema "strategy_evaluations" do
    field(:strategy_config_id, :binary_id)
    field(:stage, :string)
    field(:status, :string, default: "pending")
    field(:stats, :map)
    field(:failure_reason, :string)
    field(:evaluated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, [:strategy_config_id, :stage, :status, :stats, :failure_reason, :evaluated_at])
    |> validate_required([:strategy_config_id, :stage])
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:status, @statuses)
  end

  @spec stages() :: [String.t()]
  def stages, do: @stages

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
