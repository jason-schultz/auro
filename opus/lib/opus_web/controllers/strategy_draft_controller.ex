defmodule OpusWeb.StrategyDraftController do
  use OpusWeb, :controller

  import Ecto.Query

  alias Opus.Pipeline.StrategyDraft
  alias Opus.Repo

  def index(conn, _params) do
    drafts =
      from(d in StrategyDraft, order_by: [desc: d.updated_at])
      |> Repo.all()
      |> Enum.map(&render_draft/1)

    json(conn, %{drafts: drafts})
  end

  def create(conn, params) do
    case %StrategyDraft{} |> StrategyDraft.changeset(params) |> Repo.insert() do
      {:ok, draft} -> json(conn, render_draft(draft))
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(StrategyDraft, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "draft not found"})

      draft ->
        case draft |> StrategyDraft.changeset(params) |> Repo.update() do
          {:ok, updated} -> json(conn, render_draft(updated))
          {:error, changeset} -> changeset_error(conn, changeset)
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(StrategyDraft, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "draft not found"})

      draft ->
        Repo.delete!(draft)
        json(conn, %{deleted: true, id: id})
    end
  end

  defp render_draft(draft) do
    %{
      id: draft.id,
      name: draft.name,
      definition: draft.definition,
      last_instrument: draft.last_instrument,
      last_granularity: draft.last_granularity,
      updated_at: draft.updated_at
    }
  end

  defp changeset_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_status(422)
    |> json(%{error: "invalid draft", details: errors})
  end
end
