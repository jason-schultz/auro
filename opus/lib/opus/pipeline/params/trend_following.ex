defmodule Opus.Pipeline.Params.TrendFollowing do
  @moduledoc """
  Embedded schema for trend_following strategy parameters.
  Used to validate and coerce parameter maps coming from Ollama.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:fast_period, :integer)
    field(:slow_period, :integer)
    field(:stop_loss, :float)
    field(:take_profit, :float)
  end

  @type t :: %__MODULE__{
          fast_period: integer() | nil,
          slow_period: integer() | nil,
          stop_loss: float() | nil,
          take_profit: float() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(params \\ %__MODULE__{}, attrs) do
    params
    |> cast(attrs, [:fast_period, :slow_period, :stop_loss, :take_profit])
    |> validate_required([:fast_period, :slow_period, :stop_loss])
    |> validate_number(:fast_period, greater_than: 0)
    |> validate_number(:slow_period, greater_than: 0)
    |> validate_number(:stop_loss, less_than: 0.0)
    |> validate_number(:take_profit, greater_than: 0.0)
    |> validate_fast_slow()
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
           "fast_period" => p.fast_period,
           "slow_period" => p.slow_period,
           "stop_loss" => p.stop_loss,
           "take_profit" => p.take_profit
         }}

      error ->
        error
    end
  end

  defp validate_fast_slow(changeset) do
    fast = get_field(changeset, :fast_period)
    slow = get_field(changeset, :slow_period)

    if fast && slow && slow <= fast do
      add_error(changeset, :slow_period, "must be greater than fast_period (#{fast})")
    else
      changeset
    end
  end
end
