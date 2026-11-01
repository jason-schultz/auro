defmodule Opus.Settings.Check do
  @moduledoc """
  The Settings page's Test button: one read-only call to the provider with
  the settings as they stand (stored, else `.env`), answered in words.
  Nothing is posted: Discord's webhook is read, not sent to.
  """

  alias Opus.Settings

  @doc "Check `provider` (an entry of `Opus.Settings.providers/0`)."
  @spec run(map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{id: "oanda"}) do
    base = Opus.Oanda.Client.base_url()

    with {:ok, key} <- present(Opus.Oanda.Client.api_key(), "API key"),
         {:ok, account} <- present(Opus.Oanda.Client.account_id(), "account ID") do
      "#{base}/v3/accounts/#{account}/summary"
      |> get(auth: {:bearer, key})
      |> answer(fn %{"account" => a} ->
        "OANDA answered: account #{a["alias"] || account}, #{a["currency"]}"
      end)
    end
  end

  def run(%{id: "massive"}) do
    base = Settings.get("MASSIVE_BASE_URL") || "https://api.massive.com"

    with {:ok, key} <-
           present(Settings.get("MASSIVE_API_KEY"), "API key (saved here; .env isn't checked)") do
      "#{base}/v3/reference/tickers"
      |> get(params: [ticker: "SPY", limit: 1, apiKey: key])
      |> answer(fn _ -> "Massive answered with the saved key" end)
    end
  end

  def run(%{id: "discord"}) do
    with {:ok, url} <- present(Opus.Dashboard.Discord.webhook_url(), "webhook URL") do
      url
      |> get([])
      |> answer(fn body -> "Discord found the webhook \"#{body["name"]}\"" end)
    end
  end

  defp present(value, _what) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, what), do: {:error, "No #{what} to test."}

  defp get(url, opts) do
    Req.get(url, [retry: false, receive_timeout: 10_000] ++ opts ++ req_options())
  end

  defp answer({:ok, %{status: status, body: body}}, words) when status in 200..299,
    do: {:ok, words.(body)}

  defp answer({:ok, %{status: status}}, _words) when status in [401, 403],
    do: {:error, "Refused (#{status}): the key or account isn't right."}

  defp answer({:ok, %{status: 404}}, _words),
    do: {:error, "Not found (404): check the account ID or address."}

  defp answer({:ok, %{status: status}}, _words), do: {:error, "Answered #{status}."}
  defp answer({:error, reason}, _words), do: {:error, "Couldn't reach it: #{inspect(reason)}"}

  defp req_options, do: Application.get_env(:opus, __MODULE__, [])[:req_options] || []
end
