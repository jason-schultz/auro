# Moving Postgres from Docker to Homebrew

Moves the `auro` database from the `amplyiq-postgres` container (Postgres 17.2) into a
native Homebrew Postgres 17, on the same port and with the same `postgres`/`postgres`
login. `DATABASE_URL` in `auro_be/.env` and the Opus config then work unchanged.

The container is stopped, not deleted, so rolling back is a single `docker start`.

**What's in the container:**

| Database | Size | Owner |
|---|---|---|
| `auro` | 15 GB | Auro |
| `opus_test` | 10 MB | Auro tests; `mix test` recreates it, so it isn't moved |
| `amply-iq-dev` | 12 MB | old CRM project, retired; dumped as an archive, not moved |
| `kerno_iq_test` | 9 MB | same CRM, retired; dumped as an archive, not moved |

The CRM databases are retired. Their dumps (about 20 MB) sit in `~/pg-move` as a cheap
archive in case you ever want them back. The `kind` Kubernetes cluster in Docker Desktop
(the old Kafka experiment) is retired too, so Docker can go entirely once this move has
settled.

Disk needed: about 20 GB for the dump plus the new copy. There are 423 GB free.

Allow about an hour, during a weekend or with no trades open. Both services stay
stopped from step 2 until step 7.

## 1. Install (services still running)

```sh
brew install postgresql@17
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Don't start it yet. Docker already holds port 5432.

## 2. Stop Rust and Opus

Stop both, in their terminals or with `launchctl bootout` if they already run under
launchd. Nothing may write to the database during the dump.

## 3. Record counts for checking later

```sh
docker exec amplyiq-postgres psql -U postgres -d auro -Atc "
  select 'candles', count(*) from candles union all
  select 'candles_legacy', count(*) from candles_legacy union all
  select 'live_trades', count(*) from live_trades union all
  select 'instruments', count(*) from instruments union all
  select 'option_quotes', count(*) from option_quotes union all
  select 'migrations', count(*) from schema_migrations" | tee ~/auro-counts-before.txt
```

## 4. Dump

```sh
mkdir -p ~/pg-move && cd ~/pg-move
docker exec amplyiq-postgres pg_dumpall -U postgres --globals-only > globals.sql
docker exec amplyiq-postgres pg_dump -U postgres -Fc auro > auro.dump
docker exec amplyiq-postgres pg_dump -U postgres -Fc amply-iq-dev > amply-iq-dev.dump
docker exec amplyiq-postgres pg_dump -U postgres -Fc kerno_iq_test > kerno_iq_test.dump
ls -lh
```

The `auro` dump takes several minutes. A file of a few GB is normal, because the
custom format is compressed.

## 5. Swap the servers

```sh
docker stop amplyiq-postgres           # stop only; do not rm
docker update --restart=no amplyiq-postgres
brew services start postgresql@17
```

Homebrew's cluster has a superuser named after your macOS account, with no
password. Create the `postgres` role the apps use:

```sh
psql -d postgres -c "create role postgres with superuser login password 'postgres';"
```

`postgres` is the only role in the container (checked Oct 26), so `globals.sql` is
kept only as a record and isn't restored.

## 6. Restore

```sh
cd ~/pg-move
createdb -U postgres -h localhost auro
pg_restore -U postgres -h localhost -d auro -j 8 --no-owner --role=postgres auro.dump
psql -U postgres -h localhost -d auro -c "vacuum analyze;"
```

`-j 8` restores tables and builds indexes in parallel. Expect 15 to 30 minutes for
`auro`. Errors about extensions or ownership are worth reading. Any other error means
stop and roll back.

Check the counts:

```sh
psql -U postgres -h localhost -d auro -Atc "<same query as step 3>" > ~/auro-counts-after.txt
diff ~/auro-counts-before.txt ~/auro-counts-after.txt && echo MATCH
```

## 7. Start the services

Start Rust once, then Opus. Check:

- The engine log shows `Candle feed started` and no database errors.
- The Opus pages load, and `/strategies` shows the same strategies as before.
- `cd opus && mix test` passes. This creates `opus_test` on the new server.

## 8. Roll back (only if something is wrong)

```sh
# stop Rust and Opus
brew services stop postgresql@17
docker update --restart=unless-stopped amplyiq-postgres
docker start amplyiq-postgres
# start Rust and Opus
```

The container has every write made up to step 2. Anything written to the native
server after that is lost when you roll back.

## 9. Clean up (a week later)

Once it has run cleanly for a while:

- Delete `auro.dump` from `~/pg-move`. Keep the two CRM dumps somewhere if you want an
  archive of them.
- Remove the container and its volume, then uninstall Docker Desktop. This is
  irreversible: after it, the CRM databases exist only as those dumps.

## Notes

- **Major upgrades.** Moving from 17 to 18 later means `pg_upgrade` or a
  dump-and-restore, not changing an image tag.
- **Tuning.** Homebrew's `postgresql.conf` defaults are small. Raising
  `shared_buffers = 2GB` and `effective_cache_size = 8GB` in
  `/opt/homebrew/var/postgresql@17/postgresql.conf`, then restarting, helps queries
  over the 15 GB `candles` table. This is optional.
- **Moving to the cloud later** is the same dump and restore, followed by a change to
  `DATABASE_URL`.
