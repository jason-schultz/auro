defmodule Opus.Research do
  @moduledoc """
  The research log: every strategy idea and test, what came of it, and what
  is worth another look. The Research page reads and writes it; nothing in
  the trading path does.
  """

  import Ecto.Query, except: [update: 2, update: 3]

  alias Opus.Repo
  alias Opus.Research.Entry

  @doc """
  Entries, most recently decided first (undecided ideas last). Options
  narrow it: `:status` and `:area` match exactly, `:search` matches the
  title, summary or evidence.
  """
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    Entry
    |> where_field(:status, opts[:status])
    |> where_field(:area, opts[:area])
    |> search(opts[:search])
    |> order_by([e], desc_nulls_last: e.decided_on, desc: e.inserted_at)
    |> Repo.all()
  end

  defp where_field(query, _field, value) when value in [nil, "", "all"], do: query
  defp where_field(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  defp search(query, term) when term in [nil, ""], do: query

  defp search(query, term) do
    pattern = "%" <> String.trim(term) <> "%"

    where(
      query,
      [e],
      ilike(e.title, ^pattern) or ilike(e.summary, ^pattern) or ilike(e.evidence, ^pattern)
    )
  end

  @doc "How many entries have each status, every status present."
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    found =
      Entry
      |> group_by([e], e.status)
      |> select([e], {e.status, count(e.id)})
      |> Repo.all()
      |> Map.new()

    Map.new(Entry.statuses(), &{&1, Map.get(found, &1, 0)})
  end

  @spec get!(integer() | String.t()) :: Entry.t()
  def get!(id), do: Repo.get!(Entry, id)

  @spec change(Entry.t(), map()) :: Ecto.Changeset.t()
  def change(%Entry{} = entry, attrs \\ %{}), do: Entry.changeset(entry, attrs)

  @spec create(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Entry{} |> Entry.changeset(attrs) |> Repo.insert()

  @spec update(Entry.t(), map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def update(%Entry{} = entry, attrs), do: entry |> Entry.changeset(attrs) |> Repo.update()

  @doc """
  Move an entry to a new status. Reaching a verdict (`worked`, `failed`,
  `parked`) dates it today unless it already has a date.
  """
  @spec set_status(Entry.t(), String.t()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Entry{decided_on: nil} = entry, status) when status in ~w(worked failed parked),
    do: update(entry, %{status: status, decided_on: Date.utc_today()})

  def set_status(%Entry{} = entry, status), do: update(entry, %{status: status})
end
