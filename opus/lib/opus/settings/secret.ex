defmodule Opus.Settings.Secret do
  @moduledoc """
  Secrets at rest, the same format the engine reads and writes
  (`auro_be/src/secrets.rs`): AES-256-GCM with a random 12-byte nonce and
  the value's name as associated data (a value copied under another name
  won't open), stored as text: `enc:v1:` then hex of nonce ‖ ciphertext ‖
  tag.

  The key is `AURO_SECRETS_KEY`, 64 hex characters, the same in Opus's and
  the engine's settings (`config :opus, :secrets_key`). It never goes into
  the database, so a backup holds the values but can't read them.
  """

  @prefix "enc:v1:"

  @doc "The configured key as 32 bytes, or nil when none (or a malformed one) is set."
  @spec key() :: binary() | nil
  def key do
    with hex when is_binary(hex) <- Application.get_env(:opus, :secrets_key),
         {:ok, <<_::binary-size(32)>> = key} <- Base.decode16(String.trim(hex), case: :mixed) do
      key
    else
      _ -> nil
    end
  end

  @doc "`plain` sealed under `name`."
  @spec seal(String.t(), String.t(), binary()) :: String.t()
  def seal(name, plain, key) do
    nonce = :crypto.strong_rand_bytes(12)
    {sealed, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, name, true)
    @prefix <> Base.encode16(nonce <> sealed <> tag, case: :lower)
  end

  @doc """
  The plain value of `stored` under `name`. A value without the prefix is
  plain text and comes back as is; one that won't open (another key, the
  wrong name, damage) is `:error`.
  """
  @spec open(String.t(), String.t(), binary() | nil) :: {:ok, String.t()} | :error
  def open(name, @prefix <> hex, key) when is_binary(key) do
    with {:ok, <<nonce::binary-12, rest::binary>>} when byte_size(rest) >= 16 <-
           Base.decode16(hex, case: :lower),
         sealed = binary_part(rest, 0, byte_size(rest) - 16),
         tag = binary_part(rest, byte_size(rest) - 16, 16),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, sealed, name, tag, false) do
      {:ok, plain}
    else
      _ -> :error
    end
  end

  def open(_name, @prefix <> _, nil), do: :error
  def open(_name, plain, _key), do: {:ok, plain}

  @doc "Whether `stored` is an encrypted value."
  @spec encrypted?(String.t()) :: boolean()
  def encrypted?(stored), do: String.starts_with?(stored, @prefix)
end
