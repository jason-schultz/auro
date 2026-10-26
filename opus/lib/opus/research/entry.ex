defmodule Opus.Research.Entry do
  @moduledoc """
  One idea or test in the research log (`research_entries`): what it was,
  how it came out, the numbers that decided it and where the notes live.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(idea testing worked failed parked)
  @areas ~w(index fx commodities bonds equities options multi)

  schema "research_entries" do
    field :title, :string
    field :area, :string
    field :status, :string, default: "idea"
    field :summary, :string
    field :details, :string
    field :evidence, :string
    field :source, :string
    field :decided_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The closed set of `status` values, in the order the page shows them."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The closed set of `area` values."
  @spec areas() :: [String.t()]
  def areas, do: @areas

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:title, :area, :status, :summary, :details, :evidence, :source, :decided_on])
    |> validate_required([:title, :area, :status, :summary])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:area, @areas)
    |> validate_length(:title, max: 255)
  end
end
