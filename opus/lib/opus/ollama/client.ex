defmodule Opus.Ollama.Client do
  @base_url Application.compile_env(:opus, :ollama_base_url, "http://localhost:11434")

  def base_url, do: Application.get_env(:opus, :ollama_base_url, @base_url)

  @model "deepseek-r1:7b"
  # @model "qwen3.5"

  def generate_trend_following_strategy do
    prompt = """
    Generate a trend-following trading strategy as JSON. Keep it simple.

    Return ONLY valid JSON, no other text, no ranges, just single numbers.

    {
      "name": "strategy name",
      "type": "trend_following",
      "description": "one sentence",
      "entry": {
        "ma_fast_period": single integer between 5 and 20,
        "ma_slow_period": single integer between 20 and 50,
        "atr_multiplier": single decimal between 1.5 and 2.5
      },
      "exit": {
        "tp_ratio": single decimal between 2.0 and 3.5,
        "trailing_stop": true
      },
      "filters": {
        "min_adx": single integer between 20 and 30,
        "max_adx": null
      }
    }

    Example values: ma_fast_period: 12, ma_slow_period: 35, atr_multiplier: 2.0, tp_ratio: 2.5, min_adx: 25
    """

    generate_response(prompt)
  end

  defp generate_response(prompt) do
    body = %{
      model: @model,
      prompt: prompt,
      max_tokens: 1000,
      temperature: 0.7,
      stream: false
    }

    client()
    |> Req.post(url: "/api/generate", json: body, receive_timeout: 120_000)
    |> handle_response()
  end

  defp client do
    Req.new(
      base_url: base_url(),
      headers: [{"Content-Type", "application/json"}]
    )
  end

  # Pattern match: 200 status AND response field exists
  defp handle_response({:ok, %Req.Response{status: 200, body: %{"response" => response}}}) do
    {:ok, String.trim(response)}
  end

  # Pattern match: 200 status but no response field (unexpected shape)
  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:error, "Unexpected response shape, missing 'response' field: #{inspect(body)}"}
  end

  # Pattern match: non-200 status
  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %{status: status, body: body}}
  end

  # Pattern match: request failure
  defp handle_response({:error, reason}) do
    {:error, reason}
  end
end
