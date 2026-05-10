defmodule Opus.Pipeline.Params.MeanReversion do
  @moduledoc """
  Embedded schema for mean_reversion strategy parameters.
  Used to validate and coerce parameter maps coming from Ollama.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:ma_period, :integer)
    field(:entry_threshold, :float)
    field(:exit_threshold, :float)
    field(:stop_loss, :float)
  end

  @type t :: %__MODULE__{
          ma_period: integer() | nil,
          entry_threshold: float() | nil,
          exit_threshold: float() | nil,
          stop_loss: float() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(params \\ %__MODULE__{}, attrs) do
    params
    |> cast(attrs, [:ma_period, :entry_threshold, :exit_threshold, :stop_loss])
    |> validate_required([:ma_period, :entry_threshold, :exit_threshold, :stop_loss])
    |> validate_number(:ma_period, greater_than: 0)
    |> validate_number(:entry_threshold, less_than: 0.0)
    |> validate_number(:exit_threshold, greater_than: 0.0)
    |> validate_number(:stop_loss, less_than: 0.0)
  end

  @doc """
  Parse and validate a raw map (e.g. from Ollama JSON). Ecto handles int/float coercion.
  Returns `{:ok, string-keyed map}` or `{:error, changeset}`.
  """
  @spec from_map(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def from_map(attrs) do
    case %__MODULE__{} |> changeset(attrs) |> apply_action(:insert) do
      {:ok, p} ->
        {:ok,
         %{
           "ma_period" => p.ma_period,
           "entry_threshold" => p.entry_threshold,
           "exit_threshold" => p.exit_threshold,
           "stop_loss" => p.stop_loss
         }}

      error ->
        error
    end
  end
end
