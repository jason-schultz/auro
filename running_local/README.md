# Running Auro locally as services

The Rust engine and Opus run as per-user launchd agents rather than in terminals.
They start at login, restart after a crash, and are deployed by hand when you
choose. Nothing here deploys automatically.

| File | What it is |
|---|---|
| `com.auro.engine.plist` | Rust engine: the release binary, run from `auro_be/` |
| `com.auro.opus.plist` | Opus: the prod release, started through `bin/opus-start` |
| `bin/opus-start` | Loads `opus.env` and execs the release in the foreground |
| `opus.env.example` | Template for `opus.env` (git-ignored, holds the secrets) |
| `POSTGRES_RUNBOOK.md` | Moving the database from Docker to a native Postgres |

## Opus prod config

The prod release matches dev, minus the developer tooling:
- **Endpoint:** listens on `127.0.0.1:4321` only.
- **Database pool:** 20 connections.
- **Assets:** served from the digested build.
- **From `opus.env`:** the database URL, the secret key base and the OANDA keys.
  Dev mode reads the OANDA keys from your shell, but under launchd there is no
  shell.

## One-time setup

```sh
cd ~/source/repos/projects/carbon_and_fire/auro
mkdir -p ~/Library/Logs/auro

# Opus secrets
cp running_local/opus.env.example running_local/opus.env
(cd opus && mix phx.gen.secret)        # paste into SECRET_KEY_BASE
$EDITOR running_local/opus.env         # OANDA_ACCOUNT_ID, OANDA_API_KEY
```

Build both services. This is also the deploy step later:

```sh
(cd auro_be && cargo build --release)
(cd opus && MIX_ENV=prod mix do deps.get --only prod, compile, assets.deploy, release --overwrite)
```

Stop the terminal copies first. Only one Auro instance may run. Then load the
agents:

```sh
cp running_local/com.auro.engine.plist running_local/com.auro.opus.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.auro.engine.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.auro.opus.plist
```

## Day to day

| Task | Command |
|---|---|
| Status | `launchctl print gui/$(id -u)/com.auro.engine \| grep -E 'state\|pid\|last exit'` |
| Restart after a deploy | `launchctl kickstart -k gui/$(id -u)/com.auro.engine` (and `com.auro.opus`) |
| Stop (stays stopped) | `launchctl bootout gui/$(id -u)/com.auro.engine` |
| Start again | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.auro.engine.plist` |
| Engine logs | `auro_be/logs/` (unchanged); panics in `~/Library/Logs/auro/engine.stderr.log` |
| Opus logs | `~/Library/Logs/auro/opus.log` |

Deploying is: build (above), run any pending migrations yourself
(`cd opus && mix ecto.migrations`, then `mix ecto.migrate`), then kickstart. Kickstart
the engine once only, because each start spends a Questrade token.

Editing a plist doesn't affect the running service until it is reloaded. Copy the
plist again, run `bootout`, then `bootstrap`.

## How restarts behave

- **Engine:** restarts only after a crash, at most once every 10 minutes, so a crash
  loop can't burn through Questrade tokens. A deliberate stop stays stopped.
- **Opus:** restarts after a crash, at most once a minute.
- **Login:** both start when you log in. If Postgres isn't up yet, the engine exits
  non-zero and retries 10 minutes later. Start Postgres with `brew services` so it
  comes up first.

`opus.log` does not rotate. Opus logs at info level, so it grows slowly; truncate it
now and then if it gets large.
