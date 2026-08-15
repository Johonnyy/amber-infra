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

It also holds the ecosystem's **shared model-keyword table** (`/models`). Apps pick a
model by describing it — `fast`, `cheap`, `coding` — and resolve that word against
their own built-in defaults; this table is the override layer they all merge on top,
so re-pointing `coding` once moves the fleet instead of needing a release per app.
Amber writes it from Aperture's model picker and reads it back on a timer, and keeps
working from her own copy when the store is unreachable. See
[sync-store/README.md](sync-store/README.md).

```
caddy/         the TLS edge: one Caddyfile, one snippet per app
sync-store/    the registry, shared model keywords, Aperture's config sync   <- start here
amber/         Amber's image, compose, and self-update units
bloom/         Bloom's compose — the agent spawner, core service on Server A
secrets/       secrets.example.yaml — the single source for every generated .env
install/       install.sh, uninstall.sh, and the shell library they share
deploy/        rollback.sh, update-app.sh, update-sync-store.sh, status.sh, watchtower
backup/        sqlite + postgres snapshots, retention, restore rehearsal
ci-templates/  ci.yml and release.yml, to copy into each repo
```

## The shape of a deployment

Two OVH boxes. **Server A** (core, always on): Caddy, sync-store, Amber, Bloom, and
later notification-relay. **Server B**: individual app agents. One Caddy per box, one
snippet per app, one subdomain each.

Bloom is on Server A rather than B because of what it holds: the user's OAuth grants,
and the thing Amber delegates to. A box that has Amber but not Bloom is a box where
half her capabilities silently do not exist.

Caddy runs with `network_mode: host` and every app publishes on `127.0.0.1:<port>`
only. So every upstream is `reverse_proxy 127.0.0.1:PORT` regardless of what serves
it, there is no docker-DNS or `host.docker.internal` to get wrong, and a firewall
slip cannot expose an app past TLS.

## Adding an app

Four things, and `install.sh` checks the first three before it touches the box:

1. **`<name>/manifest.yaml` committed to this repo** — what the app needs, in the
   app's own words: its `env_prefix`, and every key it reads with a `kind` saying who
   fills it (`generated:*` the box, `supplied` you, `derived` `install.sh`, `config` a
   default). Model it on `amber/manifest.yaml`.

   This is the authority for the prefix, and it is a file rather than a habit because
   getting the prefix wrong fails **silently**: an app that embeds `agent-runtime` as
   well as `agent-mcp-py` owns a single prefix and builds both libraries' settings
   from it, so keys under any other prefix are not an error — `extra="ignore"` means
   they are simply never read. The app starts, serves, never mounts its MCP server and
   never registers, and the only symptom is the word "unregistered" in a status report
   days later.

   CI asserts that the three derived keys are spelled exactly
   `${env_prefix}_PUBLIC_URL`, `_SYNC_STORE_URL` and `_SYNC_STORE_TOKEN`, so the
   prefix and the key names cannot drift apart. Run the same checks locally with
   `bash -c '. install/lib/manifest.sh && manifest_lint_all'`.
2. **`<name>/docker-compose.prod.yml` committed to this repo.** There is deliberately
   no generic template. An app's volume, health check and loopback port binding are
   its own, and a rendered guess is how you get a container that starts and stores
   nothing. Model it on `sync-store/docker-compose.prod.yml`.
3. **A stanza under `apps:`** in `/etc/amber-infra/secrets.yaml` — domain, upstream,
   pinned image, and the keys the manifest says you have to supply. Aperture's Servers
   tab writes this for you; the commented template at the bottom of
   `secrets.example.yaml` is the same thing by hand. `env_prefix` here is optional and
   only cross-checked — the manifest decides, and `install.sh` refuses rather than
   picking a side if the two disagree.
4. **DNS already pointing here**, because Caddy asks for a certificate the moment the
   site block appears and Let's Encrypt rate-limits failures per domain.

Nothing is declared before it exists. An app in this file is a claim that the app is
real: it becomes a row in every status report, its placeholders become entries in
every "still to do" list, and its install stops at *no compose file* — which is a
confusing way to discover that you have not written it yet.

Then:

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

## Releasing

Two kinds of change live in this repo and only one of them needs a tag.

**Shell and config — install.sh, status.sh, the lib/, the Caddyfile, this README.**
No tag. Boxes get these by `git pull` on `/opt/amber-infra` (Aperture's *Update
infra* button). Push to main and they are available immediately.

**sync-store/ — the one thing here that ships as a container image.** A tag, because
that is the only thing that publishes one:

```bash
git tag v0.1.1 && git push origin v0.1.1
```

`.github/workflows/release.yml` turns ref `v0.1.1` into
`ghcr.io/<owner>/sync-store:0.1.1`. The version in the image tag *is* the git tag —
that is the whole mechanism, and it is why `sync_store.image` in secrets.yaml can pin
an exact one.

Two things that trip this up:

* **The workflow must already exist on the commit being tagged.** Actions runs the
  workflow file as it is at the pushed ref, so tagging a commit from before the
  workflow was committed triggers nothing at all — not a failure, just silence.
* **GHCR packages are private by default**, and a box pulls unauthenticated. A private
  package fails exactly like one that was never pushed. Make it public, or
  `docker login ghcr.io` on the server. `preflight_image` catches both before an
  install touches anything.

**Publishing is not deploying**, deliberately. A published image sits in the registry
until you bump the pin in secrets.yaml and reconcile. A green build is not a decision
to run something on Server A.

**Never move a tag that has been published.** The one-off exception is a tag nothing
ever built from — otherwise a server may be running `:0.1.0` while `:0.1.0` now means
different code, and every guarantee that pinning gives you is gone.

## Runbook

**What is on this box?**

```bash
sudo bash /opt/amber-infra/deploy/status.sh --json | jq .
```

Read-only, safe to poll, and the only script here that answers a program rather than
a human: Aperture's Servers tab renders it directly and drives the scripts above
through composed flags, so there is no second implementation of what any of them
decides. Without root it still works and reports `secretsReadable: false` — the app
list then degrades to what Docker alone can say. It never prints a secret: values
under `apps.*.env` and every token are dropped structurally, and only key *names* are
emitted, so a GUI can tell you `AMBER_OPENAI_API_KEY` is set without ever having seen
it.

The field worth reading is `imagePinned` vs `imageRunning`. They diverge when a pin
was bumped and nothing restarted — the state where every health check is green and
the code running is not the code you think it is.

**Update the sync-store.** It is the one thing in this repo that ships as an image, so
*Update infra* — a `git pull` — brings its source and changes nothing about what runs.
`ensure_sync_store` also returns early on a healthy store, so re-running an install
does not roll it either. This is the path:

```bash
sudo bash /opt/amber-infra/deploy/update-sync-store.sh --to 0.2.0 --dry-run
sudo bash /opt/amber-infra/deploy/update-sync-store.sh --to 0.2.0
```

A thin wrapper over `update-app.sh`, so it pulls, restarts, waits for health and
**reverts to the last image this box saw healthy** if it does not come back. What is
genuinely its own: the pin lives in two places — `sync_store.image` in secrets.yaml,
which a fresh install reads, and the deployed compose file, which is what actually
runs. It writes both, and writes secrets.yaml only *after* the store comes back, so a
version that was rejected is never recorded as the one this box wants. With no `--to`
it re-pulls the current pin, which is the "it is wedged, put it back" case.

Aperture drives it from the Registry card: the version row offers the newest
amber-infra release, and Advanced mode takes any other tag.

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
