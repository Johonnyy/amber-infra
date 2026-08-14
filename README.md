# amber-infra

The deployment backbone for the Amber ecosystem: the discovery registry, the TLS
edge, the installer, backups, and CI templates.

Its centre is **sync-store** — a small FastAPI + SQLite service that is the missing
half of a contract `agent-mcp-py` already implements. Every MCP server in the
ecosystem calls `sync_client.register()` on startup and re-registers on a heartbeat;
every agent calls `PeerRegistry.refresh()` to discover peers. Until now both talked
to nothing, which is why peer discovery was the static `AMBER_MCP_PEERS` map.

Amber needs no code change to use it. `AMBER_MCP_PUBLIC_URL`,
`AMBER_MCP_SYNC_STORE_URL` and `AMBER_MCP_SYNC_STORE_TOKEN` are already wired
through her config into `AgentMCPSettings` — `install.sh` sets them and she
registers herself.

```
caddy/         the TLS edge: one Caddyfile, one snippet per app
sync-store/    the registry + Aperture's config sync   <- start here
amber/         Amber's image, compose, and self-update units
secrets/       secrets.example.yaml — the single source for every generated .env
install/       install.sh, uninstall.sh, and the shell library they share
deploy/        rollback.sh, update-amber.sh, migrate-amber-db.sh, watchtower
backup/        sqlite + postgres snapshots, retention, restore rehearsal
ci-templates/  ci.yml and release.yml, to copy into each repo
```

## The shape of a deployment

Two OVH boxes. **Server A** (core, always on): Caddy, sync-store, Amber, and later
agent-spawner and notification-relay. **Server B**: individual app agents. One Caddy
per box, one snippet per app, one subdomain each.

Caddy runs with `network_mode: host` and every app publishes on `127.0.0.1:<port>`
only. So every upstream is `reverse_proxy 127.0.0.1:PORT` regardless of what serves
it, there is no docker-DNS or `host.docker.internal` to get wrong, and a firewall
slip cannot expose an app past TLS.

## Adding an app

```bash
sudo bash /opt/amber-infra/install/install.sh \
     --app finance --domain finance.johnny.dev --upstream 127.0.0.1:8090 --dry-run
```

`--dry-run` prints every mutating action and changes nothing. Drop it to run for
real. Everything the installer cannot infer comes from `/etc/amber-infra/secrets.yaml`
— it never prompts for a secret that belongs in that file, because a value invented
at a prompt is a value that is not in your backups.

It ensures Docker and the firewall, brings up Caddy, renders the app's `.env`,
deploys the container on a **pinned** tag, ensures the sync-store, writes the three
discovery keys, adds the Caddy site, and then **waits for the app to register
itself**.

That last step is deliberate: `install.sh` never POSTs a descriptor on an app's
behalf. Registration is `agent_mcp`'s job on startup; doing it from bash would leave
a registry entry that outlives the app being broken — a peer every agent believes in
and nothing answers for. The installer's job is to make registration possible and
then assert it happened.

## Where Amber lives now

Amber runs as a container on Server A, exact-pinned, behind Caddy at
`amber.<domain>`. Two things survived the move from systemd:

**The voice self-update.** `AMBER_UPDATE_COMMAND` runs *inside* her process, where
there is no `systemctl` and no Docker socket. So it became
`touch /signals/update-requested`; `amber-update.path` on the host watches for that
file and runs `deploy/update-amber.sh`, which reconciles the env file, pulls, waits
for health, and **reverts to the previous image if she does not come back**. That
last part matters more here than anywhere else: an update that leaves Amber unable
to hear the next instruction is the one failure that cannot fix itself.

The alternatives were mounting the Docker socket into her container — root on the
host, reachable by anything the model can be talked into invoking — or an updater
sidecar holding the socket behind an HTTP endpoint. A file is less surface than
either, and it matches the semantics she already had: the `systemd-run` version was
fire-and-forget too, so she has always said "started", never "finished".

**Her `.env` reconciliation.** `update.sh`'s key-diff against `.env.example` is now
`install/lib/env.sh::env_reconcile`, reading the example baked into the image at
`/srv/.env.example`. `env_set` is copied verbatim from `amber_v2/deploy/update.sh`,
and that is load-bearing: two writers with two escaping rules is how an env file
grows a duplicate key, and a duplicate key resolves to whichever one the parser saw
last.

Migrating an existing box:

```bash
sudo bash /opt/amber-infra/deploy/migrate-amber-db.sh --dry-run
```

`amber.db` is WAL-mode SQLite with three co-tenant writers (memory, `agent_mcp_usage`,
`agent_runtime_usage`), so the script uses `sqlite3 .backup` and verifies with
`PRAGMA integrity_check` — **a `cp` of that file is a corrupt snapshot**, not a
backup. It leaves `/opt/amber` and the systemd unit intact but stopped; that is the
rollback (`systemctl start amber`). Remove them after a good day on the container,
not before.

`amber_v2/deploy/` still works and is still the right way to run Amber on a dev VPS
or any box without Docker.

## Runbook

**Rotate a peer token.** Edit `sync_store.keys[]` in `secrets.yaml`, re-run
`install.sh --app <name>`, restart the app. To change the credential *Amber presents
to a peer*, use the store instead:

```bash
curl -X PUT https://sync.johnny.dev/servers/finance/token \
     -H "Authorization: Bearer $ADMIN" -d '{"token":"..."}'
```

That column is admin-only and is deliberately absent from the registration upsert —
otherwise the 300-second heartbeat would wipe every peer credential in the ecosystem
five minutes after it was set.

**An app is not discoverable.** `agent_mcp`'s `register()` logs and swallows every
failure, so the reason is only ever in the *app's* log:

```bash
docker logs <app> --tail 100 | grep -i 'sync store'
```

Usually: `*_PUBLIC_URL` unset (registration refuses before any HTTP is attempted),
or a token that does not match an entry in `sync_store.keys`.

**Roll back.**

```bash
deploy/rollback.sh amber --list        # tags on disk + the deploy journal
deploy/rollback.sh amber 0.1.0
```

It backs up the compose file first and restores it if the target does not become
healthy. The previous image being on disk is what makes this work offline, which is
why `WATCHTOWER_CLEANUP` is off on Server A.

**Restore a backup.**

```bash
backup/backup-sqlite.sh --list
gunzip -c /var/backups/amber-infra/amber-<stamp>.db.gz > /tmp/restore.db
sqlite3 /tmp/restore.db 'PRAGMA integrity_check'
docker compose -f /etc/amber-infra/amber/docker-compose.prod.yml down
docker run --rm -v amber-data:/data -v /tmp:/src alpine cp /src/restore.db /data/amber.db
docker compose -f /etc/amber-infra/amber/docker-compose.prod.yml up -d
```

The weekly cron line runs `--verify-latest`, which actually restores the newest
snapshot and checks it. It is the only line in that file that proves the other two
are worth anything.

**Watchtower.** Only on Server B, and only for containers that opt in with
`com.centurylinklabs.watchtower.enable: "true"`. It mounts the Docker socket, which
is root on the host — a bad thing to hand a polling daemon on the box holding
Amber's API keys and the registry credentials. Note also that Watchtower and pinned
tags are in genuine tension: it acts when a tag's *digest* moves, so an exact-pinned
container is one it correctly never touches. Server B apps run `:stable` — a moving
tag that is still not `:latest`, republished by `release.yml` only after CI is green.

## CI

`ci-templates/ci.yml` is tests only — no ruff, no mypy. No repo in the ecosystem has
ever had lint config, so adopting one is a config decision plus a cleanup backlog
across four working repos, and burying that inside an infrastructure change lands
both badly. It should be its own pass.

This repo's own `.github/workflows/ci.yml` adds three *config* validation jobs, which
are a different thing: `shellcheck -x`, `caddy validate`, and `docker compose config`
— plus a grep that fails the build if any `docker-compose.prod.yml` grows a floating
tag. That last one is what keeps "never `latest`" true six months from now.

## Known ecosystem wart

`mcp_path` is stored and served by sync-store, but nothing reads it —
`agent_mcp.registry` hardcodes `MCP_MOUNT_PATH = "/mcp"`. Left alone: making it
meaningful is a change to the library, not to this repo.
