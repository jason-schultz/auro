defmodule Opus.Pipeline.StrategyEvaluation do
  @moduledoc """
  Ecto schema for per-stage pipeline evaluation results.

  `rules_version` is the version of the pipeline's rules a finished stage
  was judged by, stamped by the tester (`RULES_VERSION` in
  `auro_be/src/engine/pipeline.rs`); nil for results from before stamping.
  `current?/1` says whether a result was judged by today's rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The rules version the tester stamps results with, written from the Rust
  # constant by a Rust test (which fails when this file is stale) and read
  # here at compile time, so Opus knows it while the tester is down.
  @rules_version_path Path.expand("../../../priv/rules_version.json", __DIR__)
  @external_resource @rules_version_path
  @rules_version @rules_version_path
                 |> File.read!()
                 |> Jason.decode!()
                 |> Map.fetch!("rules_version")

  @stages ~w[backtest walk_forward monte_carlo parameter_stability holdout]
  @statuses ~w[pending running passed failed]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          strategy_config_id: Ecto.UUID.t() | nil,
          stage: String.t() | nil,
          status: String.t() | nil,
          stats: map() | nil,
          failure_reason: String.t() | nil,
          rules_version: integer() | nil,
          evaluated_at: DateTime.t() | nil
        }

  schema "strategy_evaluations" do
    field(:strategy_config_id, :binary_id)
    field(:stage, :string)
    field(:status, :string, default: "pending")
    field(:stats, :map)
    field(:failure_reason, :string)
    field(:rules_version, :integer)
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

  @doc "The version of the rules the pipeline judges by today."
  @spec rules_version() :: pos_integer()
  def rules_version, do: @rules_version

  @doc """
  Whether a result was judged by today's rules: stamped with the current
  rules version. Unstamped (before stamping) or lower is an old test.
  """
  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{rules_version: version}),
    do: is_integer(version) and version >= @rules_version

  @spec stages() :: [String.t()]
  def stages, do: @stages

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
