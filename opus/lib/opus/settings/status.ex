defmodule Opus.Settings.Status do
  @moduledoc """
  What an integration's tile and panel say about it, from real checks,
  never from a value merely being saved:

    - an engine connection (OANDA, Massive): the engine's own report of what
      it has in use (`GET /api/settings/status`);
    - Questrade: whether the engine is connected with its token;
    - Discord: Opus's last check (`Opus.Settings.record_check/3`).

  `of/2` answers `{state, word, line}`: the state (`:working`, `:problem`,
  `:restart`, `:none`, `:checking`, `:unknown`), the short word under a
  tile and the longer line in its panel.
  """

  alias Opus.Settings

  @type state :: :working | :problem | :restart | :none | :checking | :unknown

  @typedoc """
  What's known so far: the engine's statuses and Questrade's (nil until
  they arrive, `{:error, words}` when the engine didn't answer) and
  Opus's own views of the saved fields (`Opus.Settings.view/1`), by id.
  """
  @type known :: %{engine: term(), questrade: term(), views: map()}

  @spec of(map(), known()) :: {state(), String.t(), String.t()}
  def of(%{kind: :not_yet}, _known), do: {:none, "Not set up", "Not set up."}

  def of(%{kind: :questrade}, %{questrade: nil}), do: checking()

  def of(%{kind: :questrade}, %{questrade: {:ok, %{"connected" => true}}}),
    do: {:working, "Connected", "Connected."}

  def of(%{kind: :questrade}, %{questrade: {:ok, status}}),
    do:
      {:problem, "Not connected",
       "Not connected#{if status["error"], do: ": #{status["error"]}", else: "."}"}

  def of(%{kind: :questrade}, %{questrade: {:error, words}}),
    do: {:unknown, "Unknown", "Couldn't tell: #{words}"}

  def of(%{engine: _}, %{engine: nil}), do: checking()

  def of(%{engine: _}, %{engine: {:error, words}}),
    do: {:unknown, "Unknown", "Couldn't ask the engine: #{words}"}

  def of(%{engine: connection}, %{engine: {:ok, statuses}}),
    do: engine(statuses[connection] || %{})

  def of(integration, %{views: views}) do
    check = get_in(views, [integration.id, :check])

    cond do
      not Settings.set_up?(integration) -> {:none, "Not set up", "Not set up."}
      check && check.ok == false -> {:problem, "Problem", check.words}
      true -> {:working, "In use", "In use."}
    end
  end

  @doc "The integrations in the Problem or Restart state, with their lines."
  @spec needing_attention(known()) :: [{map(), String.t()}]
  def needing_attention(known) do
    for {_group, integrations} <- Settings.groups(),
        %{kind: kind} = integration <- integrations,
        kind != :later,
        {state, _word, line} = of(integration, known),
        state in [:problem, :restart],
        do: {integration, line}
  end

  defp checking, do: {:checking, "Checking…", "Asking the engine…"}

  defp engine(%{"restart_to_switch" => true} = status),
    do: {:restart, "Restart to switch", status["words"]}

  defp engine(%{"ok" => false} = status), do: {:problem, "Problem", status["words"]}

  defp engine(%{"in_use_since" => since}) when is_binary(since),
    do: {:working, "In use", "In use since #{stamp(since)}."}

  defp engine(_status), do: {:none, "Not set up", "Not set up."}

  defp stamp(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> OpusWeb.Format.clock(at) <> ", " <> OpusWeb.Format.date(at)
      _ -> iso
    end
  end
end
