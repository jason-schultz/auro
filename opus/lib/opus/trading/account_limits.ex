defmodule Opus.Trading.AccountLimits do
  @moduledoc """
  The account-level safety limits (`trading_config.account_limits`),
  edited on the Safety page:

  - `drawdown_pause_pct`: pause every new entry when NAV falls this far
    below its peak since `since` or the last reset (`Opus.Trading.AccountPause`).
  - `risk_budget_pct`: the most of NAV at risk across open trades at once.
  - `max_open_per_group`: open trades allowed per asset class at once.
  - `breaker_losses`, `breaker_drawdown_pct`, `breaker_window_days`: the
    per-strategy circuit breaker (`Opus.Trading.CircuitBreaker`) trips on
    that many losing trades in a row, or trade returns summing below minus
    that percent over that many days.
  - `since`: when the limits took effect.

  The risk budget and group cap are enforced by the engine when a trade
  opens (pushed with the rules, `Opus.Trading.RulesEngine`). Every change,
  here or to a strategy's breaker exemption, is logged in
  `account_limit_changes` (`Opus.Trading.AccountLimitChange`).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Opus.Repo
  alias Opus.Trading.{AccountLimitChange, LiveStrategy, Strategies}

  @type t :: %{
          drawdown_pause_pct: number(),
          risk_budget_pct: number(),
          max_open_per_group: pos_integer(),
          breaker_losses: pos_integer(),
          breaker_drawdown_pct: number(),
          breaker_window_days: pos_integer(),
          since: DateTime.t()
        }

  # Each editable setting: its key, whether it's whole, the range a person
  # may set, and whether raising it loosens it (more room for losses or
  # risk). A longer breaker window is neither looser nor tighter.
  @settings [
    {:drawdown_pause_pct, :float, 1, 50, true},
    {:risk_budget_pct, :float, 0.5, 20, true},
    {:max_open_per_group, :integer, 1, 10, true},
    {:breaker_losses, :integer, 2, 20, true},
    {:breaker_drawdown_pct, :float, 1, 50, true},
    {:breaker_window_days, :integer, 7, 90, false}
  ]

  # What a trade risks when its strategy's sizing doesn't say: the engine's
  # default (DEFAULT_POSITION_RISK in Rust).
  @default_risk 0.01

  @doc "The editable settings, in display order."
  @spec keys() :: [atom()]
  def keys, do: Enum.map(@settings, &elem(&1, 0))

  @doc "The range a setting may take, `{min, max}`."
  @spec range(atom()) :: {number(), number()}
  def range(key) do
    {^key, _kind, min, max, _loosens} = List.keyfind!(@settings, key, 0)
    {min, max}
  end

  @doc """
  Whether changing `setting` (as the change log names it) from `old` to
  `new` loosens it: a higher limit, or exempting a strategy from the breaker.
  """
  @spec loosens?(String.t() | atom(), term(), term()) :: boolean()
  def loosens?(setting, old, new) when is_binary(setting) and setting != "circuit_breaker_exempt",
    do: loosens?(String.to_existing_atom(setting), number(old), number(new))

  def loosens?("circuit_breaker_exempt", _old, new), do: new in [true, "true"]

  def loosens?(key, old, new) when is_atom(key) do
    {^key, _kind, _min, _max, raising_loosens} = List.keyfind!(@settings, key, 0)
    raising_loosens and new > old
  end

  defp number(value) when is_number(value), do: value

  defp number(text) when is_binary(text) do
    {value, _} = Float.parse(text)
    value
  end

  @doc "The limits, or nil before the migration that sets them has run."
  @spec get() :: t() | nil
  def get do
    from(c in "trading_config", where: c.key == "account_limits", select: c.value)
    |> Repo.one()
    |> parse()
  end

  defp parse(%{"since" => since} = value) do
    keys()
    |> Map.new(&{&1, Map.fetch!(value, Atom.to_string(&1))})
    |> Map.put(:since, Opus.Utils.Time.parse_iso8601!(since))
  end

  defp parse(nil), do: nil

  @doc """
  The settings `params` (string keys, as a form sends them) would change,
  each `%{key, old, new, loosens?}`; unchanged ones are left out. Or
  `{:error, messages}` naming each value out of range.
  """
  @spec diff(t(), map()) :: {:ok, [map()]} | {:error, %{atom() => String.t()}}
  def diff(current, params) do
    {changes, errors} =
      Enum.reduce(@settings, {[], %{}}, fn {key, kind, min, max, _loosens}, {changes, errors} ->
        old = Map.fetch!(current, key)

        case cast(params[Atom.to_string(key)], kind, min, max) do
          {:ok, new} when new == old ->
            {changes, errors}

          {:ok, new} ->
            change = %{key: key, old: old, new: new, loosens?: loosens?(key, old, new)}
            {[change | changes], errors}

          :error ->
            {changes, Map.put(errors, key, "Pick a number from #{min} to #{max}.")}
        end
      end)

    if errors == %{}, do: {:ok, Enum.reverse(changes)}, else: {:error, errors}
  end

  defp cast(text, kind, min, max) when is_binary(text) do
    parsed =
      case kind do
        :integer -> Integer.parse(String.trim(text))
        :float -> Float.parse(String.trim(text))
      end

    case parsed do
      {value, ""} when value >= min and value <= max -> {:ok, value}
      _ -> :error
    end
  end

  defp cast(_missing, _kind, _min, _max), do: :error

  @doc "Save `changes` (from `diff/2`) and log each one, in one transaction."
  @spec save([map()], DateTime.t()) :: {:ok, t()} | {:error, term()}
  def save(changes, now \\ DateTime.utc_now()) do
    patch = Map.new(changes, &{Atom.to_string(&1.key), &1.new})

    limits =
      from(c in "trading_config",
        where: c.key == "account_limits",
        update: [
          set: [value: fragment("? || ?", c.value, type(^patch, :map)), updated_at: ^now]
        ]
      )

    Multi.new()
    |> Multi.update_all(:limits, limits, [])
    |> Multi.insert_all(
      :log,
      AccountLimitChange,
      Enum.map(changes, &log_row(Atom.to_string(&1.key), nil, &1.old, &1.new, now))
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, get()}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  @doc """
  Exempt a strategy from the circuit breaker, or stop exempting it, and log
  the change. Exempting loosens a rule, so the page asks first.
  """
  @spec set_exempt(Ecto.UUID.t(), boolean(), DateTime.t()) ::
          {:ok, boolean()} | {:error, term()}
  def set_exempt(id, exempt, now \\ DateTime.utc_now()) when is_boolean(exempt) do
    case Repo.get(LiveStrategy, id) do
      nil ->
        {:error, :not_found}

      %{circuit_breaker_exempt: ^exempt} ->
        {:ok, exempt}

      strategy ->
        subject = "#{Strategies.display_name(strategy)} on #{strategy.instrument}"

        Multi.new()
        |> Multi.update(
          :strategy,
          Ecto.Changeset.change(strategy, circuit_breaker_exempt: exempt)
        )
        |> Multi.insert_all(:log, AccountLimitChange, [
          log_row("circuit_breaker_exempt", subject, !exempt, exempt, now)
        ])
        |> Repo.transaction()
        |> case do
          {:ok, _} -> {:ok, exempt}
          {:error, _step, reason, _done} -> {:error, reason}
        end
    end
  end

  defp log_row(setting, subject, old, new, now) do
    %{
      setting: setting,
      subject: subject,
      old_value: to_string(old),
      new_value: to_string(new),
      changed_at: now
    }
  end

  @doc "The latest changes, newest first."
  @spec changes(pos_integer()) :: [AccountLimitChange.t()]
  def changes(limit \\ 20) do
    from(c in AccountLimitChange, order_by: [desc: c.changed_at, desc: c.id], limit: ^limit)
    |> Repo.all()
  end

  @doc """
  Each instrument's group for the concentration cap: its asset class, with
  FX majors and crosses as one group. An instrument with no class is left
  out, and the engine treats it as a group of its own.
  """
  @spec groups([String.t()]) :: %{String.t() => String.t()}
  def groups(instruments) do
    from(i in "instruments",
      where: i.oanda_symbol in ^Enum.uniq(instruments),
      select: {i.oanda_symbol, i.asset_class}
    )
    |> Repo.all()
    |> Map.new(fn
      {symbol, "fx_" <> _} -> {symbol, "fx"}
      {symbol, class} -> {symbol, class}
    end)
  end

  @doc """
  The share of NAV each of a strategy's trades risks, from its sizing
  (`%{"type" => "RiskPct", "params" => %{"pct" => 0.01}}`), or nil when the
  sizing doesn't say.
  """
  @spec risk_pct(map() | nil) :: number() | nil
  def risk_pct(%{"type" => "RiskPct", "params" => %{"pct" => pct}}) when is_number(pct), do: pct
  def risk_pct(_sizing), do: nil

  @doc "What a trade counts against the budget: its sizing's share, or the engine's default."
  @spec counted_risk(map() | nil) :: number()
  def counted_risk(sizing), do: risk_pct(sizing) || @default_risk
end
