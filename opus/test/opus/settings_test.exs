defmodule Opus.SettingsTest do
  use Opus.DataCase, async: true

  alias Opus.Settings
  alias Opus.Settings.{Check, Setting}

  test "a secret is stored encrypted, read back plain, and shown only by its end" do
    assert :ok = Settings.put("OANDA_API_KEY", " abcd-1234-wxyz ")
    stored = Repo.get!(Setting, "OANDA_API_KEY").value
    assert String.starts_with?(stored, "enc:v1:")
    refute stored =~ "wxyz"

    assert Settings.get("OANDA_API_KEY") == "abcd-1234-wxyz"

    %{fields: [key | _]} = Settings.view(Settings.integration("oanda-practice"))
    assert %{stored: true, ends: "wxyz"} = key
    refute Map.has_key?(key, :value)
  end

  test "a plain setting is shown in full; a blank one is removed so .env applies" do
    :ok = Settings.put("OANDA_ACCOUNT_ID", "101-002-1")
    assert Settings.get("OANDA_ACCOUNT_ID") == "101-002-1"
    assert Opus.Oanda.Client.account_id() == "101-002-1"

    :ok = Settings.put("OANDA_ACCOUNT_ID", "")
    assert Settings.get("OANDA_ACCOUNT_ID") == nil
    assert Settings.put("NOT_A_SETTING", "x") == {:error, :unknown}
  end

  test "without the key, a secret can't be saved" do
    key = Application.get_env(:opus, :secrets_key)
    Application.put_env(:opus, :secrets_key, nil)
    on_exit(fn -> Application.put_env(:opus, :secrets_key, key) end)

    assert Settings.put("DISCORD_WEBHOOK_URL", "https://x") == {:error, :no_key}
    refute Settings.key_set?()
  end

  test "the Discord test reads the saved webhook without posting to it" do
    :ok = Settings.put("DISCORD_WEBHOOK_URL", "https://discord.test/api/webhooks/9/tok")

    Req.Test.stub(Check, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/webhooks/9/tok"
      Req.Test.json(conn, %{"name" => "Auro alerts"})
    end)

    assert Check.run(Settings.integration("discord")) ==
             {:ok, ~s(Discord found the webhook "Auro alerts". Nothing was posted.)}
  end

  test "a refused webhook says so, and the check's outcome is kept with its words" do
    discord = Settings.integration("discord")
    :ok = Settings.put("DISCORD_WEBHOOK_URL", "https://discord.test/api/webhooks/9/gone")
    Req.Test.stub(Check, &Plug.Conn.send_resp(&1, 404, ""))

    assert {:error, words} = Check.run(discord)
    assert words =~ "Discord refused it (404)"

    :ok = Settings.record_check(discord, false, words)
    assert %{check: %{ok: false, words: ^words}} = Settings.view(discord)
  end

  test "integrations come in page order, alphabetical within each group" do
    assert [{"Brokers", brokers}, {"Market data", _}, {"AI", _}, {"Notifications", _}] =
             Settings.groups()

    names = Enum.map(brokers, & &1.name)
    assert names == Enum.sort(names)
    refute "Wealthsimple" in names
  end
end
