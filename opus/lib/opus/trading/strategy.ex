defmodule Opus.Contexts.Strategy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "strategies" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: [:trend_following, :mean_reversion, :breakout, :other])
    field(:description, :string)

    embeds_one :entry, Entry, primary_key: false do
      field(:ma_fast_period, :integer)
      field(:ma_slow_period, :integer)
      field(:atr_multiplier, :float)
    end

    embeds_one :exit, Exit, primary_key: false do
      field(:tp_ratio, :float)
      field(:trailing_stop, :boolean)
    end

    embeds_one :filters, Filters, primary_key: false do
      field(:min_adx, :integer)
      field(:max_adx, :integer)
    end

    timestamps()
  end

  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [:name, :type, :description])
    |> validate_required([:name, :type, :description])
    |> cast_embed(:entry, with: &entry_changeset/2, required: true)
    |> cast_embed(:exit, with: &exit_changeset/2, required: true)
    |> cast_embed(:filters, with: &filters_changeset/2, required: true)
  end

  defp entry_changeset(schema, attrs) do
    cast(schema, attrs, [:ma_fast_period, :ma_slow_period, :atr_multiplier])
    |> validate_number(:ma_fast_period, greater_than: 0)
  end

  defp exit_changeset(schema, attrs) do
    cast(schema, attrs, [:tp_ratio, :trailing_stop])
  end

  defp filters_changeset(schema, attrs) do
    cast(schema, attrs, [:min_adx, :max_adx])
  end
end
