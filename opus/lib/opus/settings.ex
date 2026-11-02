defmodule Opus.Settings do
  @moduledoc """
  The keys and accounts the lab connects with, entered on the Settings
  page and kept in the `settings` table instead of `.env`.

  Each setting is stored under the name its `.env` variable has
  (`OANDA_API_KEY`), so both apps read it the same way: the stored value
  first, else the `.env` one. A secret is stored encrypted
  (`Opus.Settings.Secret`) and never shown again, only how it ends.

  A saved change applies without a restart: Opus reads its settings on
  each use, and the engine checks a connection's saved values and puts them
  in use when asked (`Opus.Auro.Client.apply_settings/1`). Only switching
  the OANDA account itself waits for an engine restart.

  `integrations/0` is the catalog the page is drawn from, by group. A new
  integration is a new entry here. Brokers that forbid automated access
  aren't integrations (Wealthsimple's holdings are entered by hand on the
  Accounts page).
  """

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Settings.{Secret, Setting}

  @groups ["Brokers", "Market data", "AI", "Notifications"]

  # kind: :keyed (fields saved here), :questrade (a one-use token handed to
  # the engine), :not_yet (shown, not set up yet), :later (a placeholder).
  # engine: the engine's name for the connection when the engine uses it;
  # it then checks saved values itself.
  @integrations [
    %{id: "alpaca", name: "Alpaca", group: "Brokers", initials: "Al", kind: :later},
    %{id: "ibkr", name: "Interactive Brokers", group: "Brokers", initials: "IB", kind: :later},
    %{
      id: "oanda-practice",
      name: "OANDA Practice",
      group: "Brokers",
      initials: "OA",
      tone: "blue",
      kind: :keyed,
      engine: "oanda",
      about:
        "The broker the engine trades on with practice money, and where Opus checks closed trades.",
      used_by: [:engine, :opus],
      fields: [
        %{
          name: "OANDA_API_KEY",
          label: "API key",
          secret: true,
          hint: "A new key is checked with OANDA first; if it fails, the one in use stays."
        },
        %{
          name: "OANDA_ACCOUNT_ID",
          label: "Account ID",
          secret: false,
          hint:
            "Switching to another account needs an engine restart; the current one keeps trading until then."
        }
      ]
    },
    %{
      id: "oanda-real",
      name: "OANDA Real",
      group: "Brokers",
      initials: "OA",
      tone: "blue",
      kind: :not_yet,
      about:
        "Real money. When a strategy runs on both, its real order will go first and the practice account keeps running as the control. Set up when a real account is funded: the lab doesn't trade real money yet."
    },
    %{
      id: "questrade",
      name: "Questrade",
      group: "Brokers",
      initials: "Q",
      tone: "green",
      kind: :questrade,
      about: "Canadian prices, option chains and the TFSA's balances. Read only.",
      used_by: [:engine]
    },
    %{id: "fred", name: "FRED", group: "Market data", initials: "F", kind: :later},
    %{
      id: "massive",
      name: "Massive",
      group: "Market data",
      initials: "M",
      tone: "teal",
      kind: :keyed,
      engine: "massive",
      about: "US stock and fund history: daily bars, dividends, option prices.",
      used_by: [:engine],
      fields: [
        %{name: "MASSIVE_API_KEY", label: "API key", secret: true},
        %{
          name: "MASSIVE_CALLS_PER_MINUTE",
          label: "Calls a minute",
          secret: false,
          hint: "5 on the free plan, 0 for no limit."
        }
      ]
    },
    %{id: "claude", name: "Claude API", group: "AI", initials: "C", kind: :later},
    %{id: "mcp", name: "MCP servers", group: "AI", initials: "MCP", kind: :later},
    %{id: "ollama", name: "Ollama", group: "AI", initials: "O", kind: :later},
    %{
      id: "discord",
      name: "Discord",
      group: "Notifications",
      initials: "D",
      tone: "indigo",
      kind: :keyed,
      about: "Where alerts and the daily check-in are posted.",
      used_by: [:opus],
      fields: [
        %{
          name: "DISCORD_WEBHOOK_URL",
          label: "Webhook URL",
          secret: true,
          hint: "In Discord: the channel's settings, Integrations, Webhooks, Copy Webhook URL."
        }
      ]
    },
    %{id: "email", name: "Email", group: "Notifications", initials: "E", kind: :later},
    %{id: "pushover", name: "Pushover", group: "Notifications", initials: "P", kind: :later}
  ]

  @fields for i <- @integrations, f <- Map.get(i, :fields, []), into: %{}, do: {f.name, f}

  # Read by the apps but no longer entered on the page (the address comes
  # with the kind of account); a value saved earlier still reads.
  @names Map.keys(@fields) ++ ["MASSIVE_BASE_URL"]

  @doc "Every integration, by group in page order, each group alphabetical."
  @spec groups() :: [{String.t(), [map()]}]
  def groups do
    for group <- @groups,
        do: {group, @integrations |> Enum.filter(&(&1.group == group)) |> Enum.sort_by(& &1.name)}
  end

  @doc "The integration `id`, or nil."
  @spec integration(String.t()) :: map() | nil
  def integration(id), do: Enum.find(@integrations, &(&1.id == id))

  @doc """
  The stored value of `name`, decrypted, or nil when none is stored (or it
  won't open with the configured key): callers then use their `.env` one.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(name) when name in @names do
    with %{value: stored} <- Repo.get(Setting, name),
         {:ok, value} when value != "" <- Secret.open(name, stored, Secret.key()) do
      value
    else
      _ -> nil
    end
  end

  @doc """
  Save `value` as `name`, encrypted when the field is secret. A blank
  value removes it, so the `.env` value applies again.
  """
  @spec put(String.t(), String.t()) :: :ok | {:error, :no_key | :unknown}
  def put(name, value) when is_binary(value) do
    with %{} = field <- @fields[name],
         {:ok, stored} <- to_store(field, String.trim(value)) do
      write(name, stored)
    else
      nil -> {:error, :unknown}
      error -> error
    end
  end

  defp to_store(_field, ""), do: {:ok, nil}

  defp to_store(%{secret: true, name: name}, value) do
    case Secret.key() do
      nil -> {:error, :no_key}
      key -> {:ok, Secret.seal(name, value, key)}
    end
  end

  defp to_store(_field, value), do: {:ok, value}

  defp write(name, nil) do
    Repo.delete_all(from(s in Setting, where: s.name == ^name))
    :ok
  end

  defp write(name, stored) do
    now = DateTime.utc_now()

    Repo.insert_all(Setting, [%{name: name, value: stored, updated_at: now}],
      on_conflict: [
        set: [value: stored, updated_at: now, tested_at: nil, test_result: nil, test_ok: nil]
      ],
      conflict_target: :name
    )

    :ok
  end

  @doc """
  What the page shows for each of `integration`'s fields: whether a value
  is stored, a secret's last four characters (never the rest), a plain
  value in full, and when it was saved. Plus the last check Opus made.
  """
  @spec view(map()) :: %{fields: [map()], check: map() | nil}
  def view(%{fields: fields}) do
    names = Enum.map(fields, & &1.name)
    rows = Map.new(Repo.all(from(s in Setting, where: s.name in ^names)), &{&1.name, &1})
    key = Secret.key()

    shown = Enum.map(fields, &Map.merge(&1, shown(&1, rows[&1.name], key)))

    check =
      rows
      |> Map.values()
      |> Enum.filter(& &1.tested_at)
      |> Enum.max_by(& &1.tested_at, DateTime, fn -> nil end)

    %{
      fields: shown,
      check: check && %{at: check.tested_at, ok: check.test_ok, words: check.test_result}
    }
  end

  def view(_integration), do: %{fields: [], check: nil}

  defp shown(_field, nil, _key), do: %{stored: false}

  defp shown(%{secret: true, name: name}, %{value: stored, updated_at: at}, key) do
    case Secret.open(name, stored, key) do
      {:ok, plain} -> %{stored: true, ends: String.slice(plain, -4..-1//1), saved_at: at}
      :error -> %{stored: true, unreadable: true, saved_at: at}
    end
  end

  defp shown(_field, %{value: value, updated_at: at}, _key),
    do: %{stored: true, value: value, saved_at: at}

  @doc """
  Whether `integration` has what it needs, saved here or in `.env`, as far
  as Opus can tell: OANDA and Discord from what Opus itself reads; an
  engine-only connection from what's saved here (its `.env` value shows in
  the engine's status instead).
  """
  @spec set_up?(map()) :: boolean()
  def set_up?(%{id: "oanda-practice"}), do: present?(Opus.Oanda.Client.api_key())
  def set_up?(%{id: "discord"}), do: present?(Opus.Dashboard.Discord.webhook_url())
  def set_up?(%{fields: [first | _]}), do: present?(get(first.name))
  def set_up?(_integration), do: false

  defp present?(value), do: is_binary(value) and value != ""

  @doc "Record the outcome of a check Opus made of `integration` on its stored rows."
  @spec record_check(map(), boolean(), String.t()) :: :ok
  def record_check(%{fields: fields}, ok, words) do
    names = Enum.map(fields, & &1.name)

    Repo.update_all(from(s in Setting, where: s.name in ^names),
      set: [tested_at: DateTime.utc_now(), test_result: words, test_ok: ok]
    )

    :ok
  end

  @doc "Whether secrets can be saved: `AURO_SECRETS_KEY` is set and well formed."
  @spec key_set?() :: boolean()
  def key_set?, do: Secret.key() != nil
end
