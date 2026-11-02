defmodule Opus.Settings.Check do
  @moduledoc """
  The Settings page's check of a connection only Opus uses: one read-only
  call with the settings as they stand (stored, else `.env`), answered in
  words. Nothing is posted: Discord's webhook is read, not sent to.

  Connections the engine uses are checked by the engine itself when it's
  asked to apply them (`Opus.Auro.Client.apply_settings/1`), so the page
  shows what's actually in use.
  """

  @doc "Check `integration` (an entry of `Opus.Settings`)."
  @spec run(map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{id: "discord"}) do
    with {:ok, url} <- present(Opus.Dashboard.Discord.webhook_url(), "webhook URL") do
      url
      |> get()
      |> answer(fn body ->
        "Discord found the webhook \"#{body["name"]}\". Nothing was posted."
      end)
    end
  end

  defp present(value, _what) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, what), do: {:error, "No #{what} to test."}

  defp get(url), do: Req.get(url, [retry: false, receive_timeout: 10_000] ++ req_options())

  defp answer({:ok, %{status: status, body: body}}, words) when status in 200..299,
    do: {:ok, words.(body)}

  defp answer({:ok, %{status: status}}, _words) when status in [401, 403, 404],
    do:
      {:error, "Discord refused it (#{status}): the webhook URL isn't right, or it was deleted."}

  defp answer({:ok, %{status: status}}, _words), do: {:error, "Discord answered #{status}."}

  defp answer({:error, reason}, _words),
    do: {:error, "Couldn't reach Discord: #{inspect(reason)}"}

  defp req_options, do: Application.get_env(:opus, __MODULE__, [])[:req_options] || []
end
