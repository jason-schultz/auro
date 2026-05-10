defmodule Opus.Ollama.Client do
  @moduledoc """
  HTTP client for Ollama. Generates revised strategy parameters from a failed backtest context.
  """

  require Logger

  alias Opus.Pipeline.Params

  @base_url Application.compile_env(:opus, :ollama_base_url, "http://localhost:11434")
  @model "deepseek-r1:7b"

  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:opus, :ollama_base_url, @base_url)

  @doc """
  Asks Ollama to revise strategy parameters based on a failed pipeline stage.

  `context` must include `failure_reason` (string) and `stats` (map of metric → value).
  Returns `{:ok, params_map}` or `{:error, reason}`.
  """
  @spec generate_revised_parameters(String.t(), map(), map(), map() | nil) ::
          {:ok, map(), String.t()} | {:error, term()}
  def generate_revised_parameters(strategy_type, current_params, context, parent_context \\ nil) do
    do_generate(strategy_type, current_params, context, parent_context, _validation_error = nil, _attempt = 0)
  end

  defp do_generate(strategy_type, current_params, context, parent_context, validation_error, attempt)
       when attempt < 2 do
    prompt = build_revision_prompt(strategy_type, current_params, context, parent_context, validation_error)

    case llm_request(prompt) do
      {:ok, raw} ->
        Logger.debug("[Ollama] raw response for #{strategy_type}: #{inspect(raw)}")
        candidate = build_candidate_params(strategy_type, current_params, raw)

        case validate_parameters(strategy_type, candidate, current_params) do
          {:ok, params} ->
            {:ok, params, prompt}

          {:error, :unchanged_parameters} = e ->
            e

          {:error, reason} ->
            Logger.debug("[Ollama] validation failed (attempt #{attempt + 1}): #{inspect(reason)}, retrying with feedback")
            do_generate(strategy_type, current_params, context, parent_context, reason, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_generate(_strategy_type, _current_params, _context, _parent_context, last_error, _attempt) do
    {:error, last_error}
  end

  # --- Prompt builders ---

  defp build_revision_prompt("trend_following", current_params, context, parent_context, validation_error) do
    p = normalize_keys(current_params)
    fast = Map.get(p, "fast_period", "?")
    slow = Map.get(p, "slow_period", "?")
    stop = Map.get(p, "stop_loss", "?")
    take = Map.get(p, "take_profit")

    """
    You are revising trading strategy parameters after a backtest failure.

    CURRENT PARAMETERS: #{Jason.encode!(current_params)}
    FAILURE: #{format_context(context, "trend_following", p)}
    #{format_progress(parent_context, current_params)}#{validation_feedback(validation_error)}
    Output a JSON object with exactly these fields:
    - "fast_period": integer (currently: #{fast})
    - "slow_period": integer, must be greater than fast_period (currently: #{slow})
    - "stop_loss": negative float (currently: #{stop})
    - "take_profit": positive float or null (currently: #{take || "null"})

    Output only the JSON object with revised numeric values. No explanation.
    """
  end

  defp build_revision_prompt("mean_reversion", current_params, context, parent_context, validation_error) do
    p = normalize_keys(current_params)
    ma = Map.get(p, "ma_period", "?")
    entry = Map.get(p, "entry_threshold", "?")
    exit_ = Map.get(p, "exit_threshold", "?")
    stop = Map.get(p, "stop_loss", "?")

    """
    You are revising trading strategy parameters after a backtest failure.

    CURRENT PARAMETERS: #{Jason.encode!(current_params)}
    FAILURE: #{format_context(context, "mean_reversion", p)}
    #{format_progress(parent_context, current_params)}#{validation_feedback(validation_error)}
    Output a JSON object with exactly these fields:
    - "ma_period": integer (currently: #{ma})
    - "entry_threshold": negative float (currently: #{entry})
    - "exit_threshold": positive float (currently: #{exit_})
    - "stop_loss": negative float (currently: #{stop})

    Output only the JSON object with revised numeric values. No explanation.
    """
  end

  defp build_revision_prompt(strategy_type, _params, _context, _parent_context, _validation_error),
    do: raise("unsupported strategy_type for Ollama revision: #{strategy_type}")

  defp validation_feedback(nil), do: ""

  defp validation_feedback(error),
    do: "PREVIOUS ATTEMPT REJECTED: #{error}. Fix these issues in your next response.\n"

  defp format_context(%{"failure_reason" => reason, "stats" => stats}, strategy_type, params) do
    format_context(%{failure_reason: reason, stats: stats}, strategy_type, params)
  end

  defp format_context(%{failure_reason: reason, stats: stats}, strategy_type, params) do
    stats_lines =
      stats
      |> Enum.map(fn {k, v} -> "  #{k}: #{v}" end)
      |> Enum.join("\n")

    num_trades = Map.get(stats, "num_trades") || Map.get(stats, :num_trades)

    zero_trade_warning =
      if num_trades == 0 do
        "\nCRITICAL: Zero trades were generated. The entry_threshold is far too restrictive. " <>
          "You MUST make entry_threshold at least 50% less negative (e.g. -0.02 → -0.01). " <>
          "A configuration with zero trades cannot be scored.\n"
      else
        ""
      end

    "What went wrong: #{humanize_failure_reason(reason, strategy_type, params)}\nBacktest stats:\n#{stats_lines}#{zero_trade_warning}"
  end

  defp format_progress(nil, _current_params), do: ""

  defp format_progress(%{params: parent_params, stats: parent_stats, current_stats: current_stats}, current_params) do
    parent_sharpe = Map.get(parent_stats, "sharpe") || Map.get(parent_stats, :sharpe)
    current_sharpe = Map.get(current_stats, "sharpe") || Map.get(current_stats, :sharpe)

    changes = describe_param_changes(parent_params, current_params)

    cond do
      not is_number(parent_sharpe) or not is_number(current_sharpe) ->
        ""

      current_sharpe > parent_sharpe ->
        delta = Float.round(current_sharpe - parent_sharpe, 3)
        "PROGRESS: Your last revision improved Sharpe from #{Float.round(parent_sharpe * 1.0, 3)} → #{Float.round(current_sharpe * 1.0, 3)} (+#{delta}). This direction is working — continue adjusting in the same direction.\nChanges made: #{changes}\n"

      current_sharpe < parent_sharpe ->
        delta = Float.round(parent_sharpe - current_sharpe, 3)
        "REGRESSION: Your last revision worsened Sharpe from #{Float.round(parent_sharpe * 1.0, 3)} → #{Float.round(current_sharpe * 1.0, 3)} (-#{delta}). These changes did not help — try a different approach.\nChanges made: #{changes}\n"

      true ->
        "NEUTRAL: Sharpe unchanged at #{Float.round(current_sharpe * 1.0, 3)}. Try a more significant parameter change.\nChanges made: #{changes}\n"
    end
  end

  defp describe_param_changes(old_params, new_params) do
    old = normalize_keys(old_params)
    new = normalize_keys(new_params)

    Enum.flat_map(Map.keys(new), fn key ->
      old_val = Map.get(old, key)
      new_val = Map.get(new, key)

      if not is_nil(old_val) and old_val != new_val do
        ["#{key}: #{old_val} → #{new_val}"]
      else
        []
      end
    end)
    |> case do
      [] -> "no changes detected"
      changes -> Enum.join(changes, ", ")
    end
  end

  defp humanize_failure_reason(reason, strategy_type, params) do
    reason
    |> String.split("; ")
    |> Enum.map(&humanize_single_constraint(&1, strategy_type, params))
    |> Enum.join("; ")
  end

  defp humanize_single_constraint(text, strategy_type, params) do
    case Regex.run(~r/^(\w+): ([\d.eE+\-]+) does not (gte|lte|gt|lt) ([\d.eE+\-]+)$/, text) do
      [_, metric, actual, op, threshold] ->
        bound = humanize_bound(op, threshold)
        hint = metric_hint(metric, op, strategy_type, params)
        "#{metric} is #{actual} (must be #{bound}) — #{hint}"

      _ ->
        text
    end
  end

  defp humanize_bound("gte", t), do: ">= #{t}"
  defp humanize_bound("lte", t), do: "<= #{t}"
  defp humanize_bound("gt", t), do: "> #{t}"
  defp humanize_bound("lt", t), do: "< #{t}"

  defp metric_hint("sharpe", _, "trend_following", params) do
    fast = Map.get(params, "fast_period", "?")
    slow = Map.get(params, "slow_period", "?")
    gap = if is_number(fast) and is_number(slow), do: slow - fast, else: "?"

    "Sharpe ratio is calculated from your trades, not set directly. " <>
      "Widen the gap between fast_period and slow_period " <>
      "(currently fast=#{fast}, slow=#{slow}, gap=#{gap}) " <>
      "so the MA crossover fires less often but only on stronger, cleaner trends."
  end

  defp metric_hint("sharpe", _, "mean_reversion", params) do
    entry = Map.get(params, "entry_threshold", "?")

    "Sharpe ratio is calculated from your trades, not set directly. " <>
      "Make entry_threshold more negative (currently #{entry}) " <>
      "so entries only occur on deeper, more reliable pullbacks rather than minor fluctuations."
  end

  defp metric_hint("sharpe", _, _, _),
    do:
      "Sharpe ratio is calculated from your trades, not set directly — filter out weaker signals to improve consistency."

  defp metric_hint("num_trades", "gte", "mean_reversion", params) do
    entry = Map.get(params, "entry_threshold", "?")
    "too few entries — make entry_threshold less negative (currently #{entry}) so the strategy fires more often on shallower pullbacks. Do NOT make it more negative."
  end

  defp metric_hint("num_trades", "gte", "trend_following", params) do
    fast = Map.get(params, "fast_period", "?")
    slow = Map.get(params, "slow_period", "?")
    gap = if is_number(fast) and is_number(slow), do: slow - fast, else: "?"
    "too few signals — narrow the MA gap (currently fast=#{fast}, slow=#{slow}, gap=#{gap}) by reducing slow_period or increasing fast_period to generate more crossover signals."
  end

  defp metric_hint("num_trades", "gte", _, _),
    do: "too few trades — loosen entry conditions to generate more signals."

  defp metric_hint("max_drawdown", "lte", "trend_following", params) do
    stop = Map.get(params, "stop_loss", "?")
    "drawdown is too large — tighten stop_loss (currently #{stop}, make it less negative) to cut losses sooner on failed trend entries."
  end

  defp metric_hint("max_drawdown", "lte", "mean_reversion", params) do
    stop = Map.get(params, "stop_loss", "?")
    "drawdown is too large — tighten stop_loss (currently #{stop}, make it less negative) so that reversions that keep moving against you are cut quickly."
  end

  defp metric_hint("max_drawdown", "lte", _, params) do
    stop = Map.get(params, "stop_loss", "?")
    "drawdown is too large — tighten stop_loss (currently #{stop}) to cut losses sooner."
  end

  defp metric_hint("expectancy", "gt", "trend_following", params) do
    fast = Map.get(params, "fast_period", "?")
    slow = Map.get(params, "slow_period", "?")
    gap = if is_number(fast) and is_number(slow), do: slow - fast, else: "?"
    "average profit per trade is negative — increase slow_period (currently #{slow}) or widen the fast/slow gap (currently #{gap}) to trade only on stronger trends."
  end

  defp metric_hint("expectancy", "gt", "mean_reversion", params) do
    entry = Map.get(params, "entry_threshold", "?")
    exit_ = Map.get(params, "exit_threshold", "?")
    "average profit per trade is negative — tighten entry_threshold (currently #{entry}, try more negative) or widen exit_threshold (currently #{exit_}) so profitable reversions fully complete."
  end

  defp metric_hint("expectancy", "gt", _, _),
    do: "average profit per trade is negative — filter entries more aggressively."

  defp metric_hint("total_return", "gt", _, _),
    do: "overall profitability is too low — improve trade quality by tightening entries."

  defp metric_hint(_, "gte", _, _), do: "value is too low."
  defp metric_hint(_, "gt", _, _), do: "value is too low."
  defp metric_hint(_, "lte", _, _), do: "value is too high."
  defp metric_hint(_, "lt", _, _), do: "value is too high."
  defp metric_hint(_, _, _, _), do: ""

  # --- Parameter validation (delegated to Ecto embedded schemas) ---

  defp validate_parameters("trend_following", candidate, current_params) do
    case Params.TrendFollowing.from_map(candidate) do
      {:ok, params} ->
        validate_changed_params(params, current_params, allowed_keys("trend_following"))

      {:error, cs} ->
        {:error, "invalid trend_following params: #{changeset_errors(cs)}"}
    end
  end

  defp validate_parameters("mean_reversion", candidate, current_params) do
    case Params.MeanReversion.from_map(candidate) do
      {:ok, params} ->
        validate_changed_params(params, current_params, allowed_keys("mean_reversion"))

      {:error, cs} ->
        {:error, "invalid mean_reversion params: #{changeset_errors(cs)}"}
    end
  end

  defp validate_parameters(strategy_type, _candidate, _current_params),
    do: {:error, "unsupported strategy_type: #{strategy_type}"}

  defp validate_changed_params(revised, current_params, keys) do
    current = current_params |> normalize_keys() |> Map.take(keys)
    revised_subset = Map.take(revised, keys)

    if revised_subset == current do
      {:error, :unchanged_parameters}
    else
      {:ok, revised}
    end
  end

  defp build_candidate_params(strategy_type, current_params, raw) do
    keys = allowed_keys(strategy_type)

    current = current_params |> normalize_keys() |> Map.take(keys)
    generated = raw |> normalize_keys() |> Map.take(keys)

    Map.merge(current, generated)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_keys(_), do: %{}

  defp allowed_keys("trend_following"),
    do: ["fast_period", "slow_period", "stop_loss", "take_profit"]

  defp allowed_keys("mean_reversion"),
    do: ["ma_period", "entry_threshold", "exit_threshold", "stop_loss"]

  defp allowed_keys(_), do: []

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  # --- HTTP ---

  defp llm_request(prompt) do
    Logger.debug("[Ollama] prompt:\n#{prompt}")

    body = %{
      model: @model,
      system:
        "You are a JSON API. Output only a valid JSON object with numeric values. No text, no explanation, no markdown.",
      prompt: prompt,
      format: "json",
      options: %{temperature: 0.3, num_predict: 200},
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

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"response" => response}}}) do
    cleaned = response |> strip_model_noise() |> String.trim()
    Logger.debug("[Ollama] cleaned response: #{inspect(cleaned)}")
    extract_json(cleaned)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:error, "unexpected Ollama response shape: #{inspect(body)}"}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %{status: status, body: body}}
  end

  defp handle_response({:error, reason}) do
    {:error, reason}
  end

  defp strip_model_noise(text) do
    text
    |> then(&Regex.replace(~r/<think>.*?(<\/think>|$)/s, &1, ""))
    |> then(&Regex.replace(~r/```json\s*/i, &1, ""))
    |> String.replace("```", "")
  end

  defp extract_json(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, "Ollama response decoded but was not a JSON object: #{inspect(text)}"}

      {:error, _} ->
        decode_first_json_object(text)
    end
  end

  defp decode_first_json_object(text) do
    text
    |> Regex.scan(~r/\{.*?\}/s)
    |> Enum.map(&hd/1)
    |> Enum.find_value(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      nil ->
        {:error, "no JSON object found in Ollama response: #{inspect(text)}"}
    end
  end
end
