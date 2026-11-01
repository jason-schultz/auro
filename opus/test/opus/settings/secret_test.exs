defmodule Opus.Settings.SecretTest do
  use ExUnit.Case, async: true

  alias Opus.Settings.Secret

  # The bytes 0..31: a known key both sides' tests share, not a secret.
  @key :binary.list_to_bin(Enum.to_list(0..31))
  # The engine's test (auro_be/src/secrets.rs) opens this same value: the two
  # sides read each other.
  @from_both "enc:v1:a0a1a2a3a4a5a6a7a8a9aaab952b1f5f20bf2fc90309f2b6577871c427e4848c944673a3675347bf"

  test "opens the value the engine's test checks, and only under its own name and key" do
    assert Secret.open("OANDA_API_KEY", @from_both, @key) == {:ok, "s3cret-value"}
    assert Secret.open("MASSIVE_API_KEY", @from_both, @key) == :error
    assert Secret.open("OANDA_API_KEY", @from_both, :binary.copy(<<17>>, 32)) == :error
    assert Secret.open("OANDA_API_KEY", @from_both, nil) == :error
  end

  test "seals with a fresh nonce each time; plain text passes through" do
    a = Secret.seal("DISCORD_WEBHOOK_URL", "https://x", @key)
    refute a == Secret.seal("DISCORD_WEBHOOK_URL", "https://x", @key)
    assert Secret.encrypted?(a)
    assert Secret.open("DISCORD_WEBHOOK_URL", a, @key) == {:ok, "https://x"}
    assert Secret.open("OANDA_BASE_URL", "https://api", @key) == {:ok, "https://api"}
  end
end
