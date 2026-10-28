defmodule Opus.Dashboard.Discord do
  @moduledoc """
  Posts to a Discord channel through its webhook (`DISCORD_WEBHOOK_URL`), so
  alerts reach the phone as push notifications. One message carries up to
  ten alerts, Discord's limit: a plain line per alert for the notification
  preview, and a coloured card each with the detail and what to do.
  """

  @per_message 10
  @colors %{act: 0xE5484D, check: 0xF5A524, fyi: 0x3E63DD}
  @level_words %{act: "Act now", check: "Check soon", fyi: "FYI"}

  @doc "Whether a webhook URL is set."
  @spec configured?() :: boolean()
  def configured?, do: url() not in [nil, ""]

  @doc """
  Posts alerts, ten to a message. Returns the keys of the alerts that went
  out: a failed message stops the rest, so they're tried again next time.
  """
  @spec post_alerts([map()]) :: {[String.t()], :ok | {:error, term()}}
  def post_alerts(alerts) do
    alerts
    |> Enum.chunk_every(@per_message)
    |> Enum.reduce_while({[], :ok}, fn chunk, {sent, :ok} ->
      case post(%{content: preview(chunk), embeds: Enum.map(chunk, &embed/1)}) do
        :ok -> {:cont, {sent ++ Enum.map(chunk, & &1.key), :ok}}
        error -> {:halt, {sent, error}}
      end
    end)
  end

  @doc "Posts a plain message: a bold title and its lines."
  @spec post_message(String.t(), [String.t()]) :: :ok | {:error, term()}
  def post_message(title, lines),
    do: post(%{content: Enum.join(["**#{title}**" | lines], "\n")})

  defp preview(alerts) do
    alerts
    |> Enum.map_join("\n", &"#{@level_words[&1.level]}: #{&1.title}")
    |> String.slice(0, 2000)
  end

  defp embed(alert) do
    description =
      [alert.detail, "**What to do:** #{alert.what_to_do}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %{
      title: String.slice(alert.title, 0, 256),
      description: String.slice(description, 0, 4096),
      color: @colors[alert.level]
    }
  end

  # A dropped connection or a Discord hiccup is retried twice before the
  # post counts as failed (a rare duplicate beats a missed alert).
  defp post(body) do
    opts = Keyword.merge([retry: :transient, max_retries: 2], req_options())

    case Req.post(url(), [json: Map.put(body, :username, "Auro")] ++ opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp url, do: config()[:webhook_url]
  defp req_options, do: config()[:req_options] || []
  defp config, do: Application.get_env(:opus, __MODULE__, [])
end
