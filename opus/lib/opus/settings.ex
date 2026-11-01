defmodule Opus.Settings do
  @moduledoc """
  The keys, accounts and addresses Auro connects with, entered on the
  Settings page and kept in the `settings` table instead of `.env`.

  Each setting is stored under the name its `.env` variable has
  (`OANDA_API_KEY`), so both apps read it the same way: the stored value
  first, else the `.env` one. A secret is stored encrypted
  (`Opus.Settings.Secret`) and never shown again, only how it ends.

  Opus reads its own settings (OANDA, Discord) on each use, so a change
  applies at once. The engine reads its settings when it starts
  (`auro_be` `Config::from_stored`), so a change to one it uses applies
  after it restarts.

  `providers/0` is the list the page is drawn from: each integration, its
  fields, which app reads it and how to check it works
  (`Opus.Settings.Check`). A new integration is a new entry here.
  """

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Settings.{Secret, Setting}

  @providers [
    %{
      id: "oanda",
      name: "OANDA",
      about: "The broker the live engine trades on, and where Opus checks closed trades.",
      used_by: [:engine, :opus],
      fields: [
        %{name: "OANDA_API_KEY", label: "API key", secret: true},
        %{name: "OANDA_ACCOUNT_ID", label: "Account ID", secret: false},
        %{
          name: "OANDA_BASE_URL",
          label: "Address",
          secret: false,
          hint: "https://api-fxpractice.oanda.com for practice, api-fxtrade for real money"
        },
        %{
          name: "OANDA_STREAM_URL",
          label: "Price stream address",
          secret: false,
          hint: "https://stream-fxpractice.oanda.com for practice"
        }
      ]
    },
    %{
      id: "massive",
      name: "Massive",
      about: "US stock and fund history: daily bars, dividends, option prices.",
      used_by: [:engine],
      fields: [
        %{name: "MASSIVE_API_KEY", label: "API key", secret: true},
        %{
          name: "MASSIVE_BASE_URL",
          label: "Address",
          secret: false,
          hint: "https://api.massive.com"
        },
        %{
          name: "MASSIVE_CALLS_PER_MINUTE",
          label: "Calls a minute",
          secret: false,
          hint: "5 on the free plan, 0 for no limit"
        }
      ]
    },
    %{
      id: "discord",
      name: "Discord",
      about: "Where alerts and the daily check-in are posted.",
      used_by: [:opus],
      fields: [%{name: "DISCORD_WEBHOOK_URL", label: "Webhook URL", secret: true}]
    }
  ]

  @names for p <- @providers, f <- p.fields, do: f.name

  @doc "Every integration the page shows, with its fields."
  @spec providers() :: [map()]
  def providers, do: @providers

  @doc "The integration `id`, or nil."
  @spec provider(String.t()) :: map() | nil
  def provider(id), do: Enum.find(@providers, &(&1.id == id))

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
    with %{} = field <- field(name),
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
      on_conflict: [set: [value: stored, updated_at: now, tested_at: nil, test_result: nil]],
      conflict_target: :name
    )

    :ok
  end

  @doc """
  What the page shows for each of `provider`'s fields: whether a value is
  stored, a secret's last four characters (never the rest), a plain
  value in full, and when it was saved. Plus the provider's last check.
  """
  @spec view(map()) :: %{fields: [map()], tested_at: DateTime.t() | nil, test_result: term()}
  def view(%{fields: fields}) do
    names = Enum.map(fields, & &1.name)
    rows = Map.new(Repo.all(from(s in Setting, where: s.name in ^names)), &{&1.name, &1})
    key = Secret.key()

    shown =
      Enum.map(fields, fn field ->
        Map.merge(field, shown(field, rows[field.name], key))
      end)

    last =
      rows
      |> Map.values()
      |> Enum.filter(& &1.tested_at)
      |> Enum.max_by(& &1.tested_at, DateTime, fn -> nil end)

    %{fields: shown, tested_at: last && last.tested_at, test_result: last && last.test_result}
  end

  defp shown(_field, nil, _key), do: %{stored: false}

  defp shown(%{secret: true, name: name}, %{value: stored, updated_at: at}, key) do
    case Secret.open(name, stored, key) do
      {:ok, plain} -> %{stored: true, ends: String.slice(plain, -4..-1//1), saved_at: at}
      :error -> %{stored: true, unreadable: true, saved_at: at}
    end
  end

  defp shown(_field, %{value: value, updated_at: at}, _key),
    do: %{stored: true, value: value, saved_at: at}

  @doc "Record the outcome of checking `provider` (`Opus.Settings.Check`) on its stored rows."
  @spec record_check(map(), String.t()) :: :ok
  def record_check(%{fields: fields}, words) do
    names = Enum.map(fields, & &1.name)

    Repo.update_all(from(s in Setting, where: s.name in ^names),
      set: [tested_at: DateTime.utc_now(), test_result: words]
    )

    :ok
  end

  @doc "Whether secrets can be saved: `AURO_SECRETS_KEY` is set and well formed."
  @spec key_set?() :: boolean()
  def key_set?, do: Secret.key() != nil

  defp field(name),
    do: Enum.find_value(@providers, fn p -> Enum.find(p.fields, &(&1.name == name)) end)
end
