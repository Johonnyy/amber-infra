#!/usr/bin/env bash
#
# Stand up one app on an OVH box: TLS edge, container, sync-store registration,
# backups. Run it again for the next app.
#
#   sudo bash /opt/amber-infra/install/install.sh \
#        --app finance --domain finance.johnny.dev --upstream 127.0.0.1:8090
#
# Idempotent throughout: re-running reconciles rather than reinstalls. Start with
# --dry-run, which prints every mutating action and changes nothing.
#
# It reads /etc/amber-infra/secrets.yaml for everything it cannot infer. It never
# prompts for a secret that belongs in that file — a value invented at a prompt is a
# value that is not in the backup.
#
# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=lib/env.sh
. "$REPO_ROOT/install/lib/env.sh"
# shellcheck source=lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=lib/manifest.sh
. "$REPO_ROOT/install/lib/manifest.sh"
# shellcheck source=lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"
# shellcheck source=lib/caddy.sh
. "$REPO_ROOT/install/lib/caddy.sh"
# shellcheck source=lib/sync_store.sh
. "$REPO_ROOT/install/lib/sync_store.sh"
# shellcheck source=lib/preflight.sh
. "$REPO_ROOT/install/lib/preflight.sh"

APP=""; DOMAIN=""; UPSTREAM=""; ROLE=""; IMAGE=""; DESCRIPTOR=""
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

usage() {
  cat <<'EOF'
Usage: install.sh --app NAME --domain FQDN [options]

  --app NAME          app name; must match a key under `apps:` in secrets.yaml
  --domain FQDN       public hostname; DNS must already point here (ACME)
  --upstream HOST:PORT  loopback upstream Caddy proxies to
                        (default: apps.<name>.upstream from secrets.yaml)
  --role core|app     core = also ensure the sync-store here
                        (default: infra.role from secrets.yaml)
  --image REF         pinned image; never a floating tag
                        (default: apps.<name>.image from secrets.yaml)
  --descriptor FILE   register FILE by hand — only for an app with no agent-mcp-py
  --secrets FILE      default /etc/amber-infra/secrets.yaml
  --dry-run           print every action, change nothing
  --skip-dns-check    proceed even when a hostname does not resolve here; only for
                      a genuinely proxied or split-horizon setup
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)        APP="$2"; shift 2 ;;
    --domain)     DOMAIN="$2"; shift 2 ;;
    --upstream)   UPSTREAM="$2"; shift 2 ;;
    --role)       ROLE="$2"; shift 2 ;;
    --image)      IMAGE="$2"; shift 2 ;;
    --descriptor) DESCRIPTOR="$2"; shift 2 ;;
    --secrets)    SECRETS_FILE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "unknown argument: $1" ;;
  esac
done

[ -n "$APP" ] || { usage; die "--app is required"; }

APP_DIR="/etc/amber-infra/$APP"
ENV_FILE="$APP_DIR/$APP.env"

# ==== 0. preflight ===========================================================
preflight_system

# ==== 1. base system =========================================================
step "Base system"
run apt-get update -qq
run apt-get install -y -qq \
    ca-certificates curl git jq sqlite3 ufw unattended-upgrades openssl cron
if ! have yq; then
  # The distro package is a different, incompatible tool on older Ubuntu. Take the
  # upstream v4 binary so `.a.b // ""` means what secrets.sh assumes it means.
  step "Installing yq (v4)"
  run bash -c 'curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq'
fi
run mkdir -p /etc/amber-infra /var/log/amber-infra /var/backups/amber-infra /var/lib/amber-infra
run chmod 700 /etc/amber-infra

if [ ! -f "$SECRETS_FILE" ]; then
  run install -m 600 "$REPO_ROOT/secrets/secrets.example.yaml" "$SECRETS_FILE"
  die "wrote a starter secrets file to $SECRETS_FILE.

     Fill in every CHANGEME, set infra.acme_email and infra.primary_domain, then
     re-run this command.

     The placeholder says which generator to use, because they are not
     interchangeable:
       CHANGEME-openssl-rand-hex-32   openssl rand -hex 32
       CHANGEME-fernet-generate-key   python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\"
     A Fernet key is 32 bytes of urlsafe base64, not hex. Bloom rejects a hex
     string at startup rather than storing an OAuth token it could not protect.
     Anything else is an API key you obtain from the provider.

     Stopping rather than guessing: a generated secret that is not in this file is
     a secret that is not in your backups."
fi
ok "secrets: $SECRETS_FILE"

ensure_docker
run ufw allow 22/tcp
run ufw allow 80/tcp
run ufw allow 443/tcp
run bash -c 'ufw --force enable >/dev/null'
ok "firewall: 22/80/443 open, everything else closed (apps bind loopback only)"

# Fill in anything not given on the command line.
[ -n "$ROLE" ]     || ROLE="$(secrets_get '.infra.role' core)"
[ -n "$DOMAIN" ]   || DOMAIN="$(secrets_require ".apps.\"$APP\".domain")"
[ -n "$UPSTREAM" ] || UPSTREAM="$(secrets_get ".apps.\"$APP\".upstream" 127.0.0.1:8000)"
[ -n "$IMAGE" ]    || IMAGE="$(secrets_get ".apps.\"$APP\".image")"
ACME_EMAIL="$(secrets_require '.infra.acme_email')"

case "$IMAGE" in
  *:latest|"")
    [ -z "$IMAGE" ] && die "no image for '$APP': set apps.$APP.image in $SECRETS_FILE or pass --image"
    die "refusing a floating tag ($IMAGE). Pin an explicit version — a restart must never change the code." ;;
esac

preflight_ports
preflight_upstream "$APP" "$UPSTREAM"
preflight_image "$IMAGE"
# What the app says it needs, checked against what it was declared with — here, in the
# preflight block, because this is the last point at which nothing has been written.
#
# The guard this replaces ran three hundred lines later, after ensure_caddy and
# secrets_render_env had already mutated the box, so "refuse rather than deploy
# something that cannot work" was not actually what it did.
manifest_check "$APP" "$SECRETS_FILE"
if [ "$ROLE" = "core" ]; then
  preflight_image "$(secrets_get '.sync_store.image')"
fi
# Every hostname this box will serve, checked together and before Caddy exists.
#
# The second one is the one nobody remembers, because nobody types it: on a core box
# the sync-store gets a site at sync.<primary_domain>, derived rather than passed.
DNS_NAMES=("$DOMAIN")
if [ "$ROLE" = "core" ]; then
  DNS_NAMES+=("sync.$(secrets_get '.infra.primary_domain')")
fi
preflight_dns_all "${DNS_NAMES[@]}"

# ==== 2. TLS edge ============================================================
ensure_caddy "$ACME_EMAIL"

# ==== 3. the app =============================================================
step "Deploying $APP ($IMAGE)"
run mkdir -p "$APP_DIR"

if [ -f "$REPO_ROOT/$APP/docker-compose.prod.yml" ]; then
  # A committed compose file wins: amber's carries the signal bind mount and the
  # data volume, which a generic template could not know about.
  run install -m 644 "$REPO_ROOT/$APP/docker-compose.prod.yml" "$APP_DIR/docker-compose.prod.yml"
else
  die "no compose file for '$APP' in this repo ($REPO_ROOT/$APP/docker-compose.prod.yml).
     Add one modelled on sync-store/docker-compose.prod.yml: pinned tag, env_file,
     a 127.0.0.1 port binding, a named volume, and a HEALTHCHECK in its image."
fi
dry || sed -i -E "s|^(\s*image:\s*)[^[:space:]]+|\1$IMAGE|" "$APP_DIR/docker-compose.prod.yml"

secrets_render_env "$APP" "$ENV_FILE"

# ==== 4. wire in agent-bridge features =======================================
#
# The app's registry token is minted BEFORE the store is brought up, and the order is
# load-bearing. `sync_store_token_for` appends a new entry to `sync_store.keys[]`, and
# the store reads `SYNC_STORE_KEYS` once, at startup. Minting afterwards produced a
# token the running store had never heard of: the app booted, served, answered its
# healthcheck, and every registration attempt was a 401 nothing surfaced. The only
# symptom was the word "unregistered" in a status report.
#
# Amber never hit it because `sync_store.keys[]` ships an `amber` entry in the example,
# so her token exists before the store first starts. The second app is the one that
# breaks — which is the same shape as the env-prefix bug: correct for the one case that
# existed, wrong for the next one.
step "Wiring $APP into the sync-store"
APP_TOKEN="$(sync_store_token_for "$APP")"
SYNC_URL="$(secrets_require '.sync_store.url')"

# Read before the store starts, for the same reason APP_TOKEN is minted before it.
# This used to sit down beside the verification step, i.e. AFTER ensure_sync_store —
# so on a box with no `amber` entry it minted one the running store had never heard
# of, and then verified with it. The check 401s, and the message blames the app.
# It never mints now; a box without the key says so instead of inventing one.
ADMIN_TOKEN="$(sync_store_admin_token)"

if [ "$ROLE" = "core" ]; then
  ensure_sync_store
  caddy_add_site sync-store "sync.$(secrets_get '.infra.primary_domain')" \
      "127.0.0.1:$(secrets_get '.sync_store.port' 8081)"
else
  # The store is not here, so nothing on this box can teach it this key. The token was
  # just written into THIS box's secrets.yaml and the store reads the CORE box's — so
  # without the same entry over there, $APP will register-401 forever and look exactly
  # like every other unregistered app. Nothing said so before; it does now, at the one
  # moment someone can act on it.
  warn "this box is role: $ROLE, so the sync-store is not here.
     '$APP' will only be able to register once the CORE box's secrets.yaml carries the
     same sync_store.keys entry for it, and its store has been reloaded there:
         sync_store.keys:  - name: $APP
                             token: $APP_TOKEN
         then on the core box:  sudo bash deploy/reload-registry.sh"
fi

# Which prefix these three keys are written under is the app's decision, not ours.
#
# Most apps embed agent-mcp-py and nothing else, so they read AGENT_MCP_* and the
# default is right. An app that embeds *both* libraries — agent-mcp-py and
# agent-runtime — cannot: it owns a single prefix and builds both libraries'
# settings from it with `_env_file=None`, precisely so two config surfaces can never
# disagree about which database to write. Amber does this (AMBER_) and so does Bloom
# (BLOOM_).
#
# Getting this wrong fails **silently**, which is why it is declared rather than
# guessed. Both apps' Settings classes use `extra="ignore"`, so an AGENT_MCP_* key
# in their env file is not an error — it is simply not read. The app starts, serves
# normally, and never registers with the sync-store, because its public URL is empty
# and registration is skipped without one. Nothing discovers it and nothing says why.
#
# This used to be `if [ "$APP" = "amber" ]`, which was correct for the one app that
# existed and wrong for the next one. Then it was a default of AGENT_MCP, which is
# correct for most apps and silently wrong for exactly the two that matter.
#
# It is now read from <app>/manifest.yaml, where CI has already checked that it agrees
# with the names of the three keys below — so the prefix and the keys it governs
# cannot disagree, rather than merely being unlikely to.
PREFIX="$(manifest_env_prefix "$APP")"
DECLARED_PREFIX="$(secrets_get ".apps.\"$APP\".env_prefix")"
DECLARED_PREFIX="${DECLARED_PREFIX%_}"

if [ -z "$PREFIX" ]; then
  # No manifest. On a current checkout this is unreachable — CI fails a compose file
  # without one — so it means the box is running an older amber-infra than the app.
  # Fall back rather than refuse: an old box should still install, loudly.
  PREFIX="${DECLARED_PREFIX:-AGENT_MCP}"
  [ -z "$DECLARED_PREFIX" ] && [ "$APP" = "amber" ] && PREFIX="AMBER_MCP"
  warn "no $APP/manifest.yaml in this checkout — falling back to '$PREFIX'.
     Update amber-infra; the manifest is what makes this checkable."
elif [ -n "$DECLARED_PREFIX" ] && [ "$DECLARED_PREFIX" != "$PREFIX" ]; then
  # Never silently prefer one. Quietly preferring a source is how the original bug
  # survived being looked at.
  die "'$APP' disagrees with itself about its env prefix.
     $APP/manifest.yaml says:            $PREFIX
     apps.$APP.env_prefix in secrets says: $DECLARED_PREFIX

     The manifest is the authority, so the fix is to correct or delete the
     env_prefix line in $SECRETS_FILE — but only you can say which of the two is
     what the app actually reads."
fi

# The keys install.sh owns. Anything set for these in secrets.yaml is overwritten
# here on every run, which is why the example file deliberately does not list them.
#
# Driven by the manifest rather than hardcoded, so an app that needs a fourth derived
# value — Bloom's BLOOM_PUBLIC_URL, the origin an OAuth provider redirects back to —
# declares it instead of being special-cased here. It was a hand-maintained CHANGEME
# that could silently disagree with the domain Caddy actually serves.
if manifest_have "$APP"; then
  DERIVED_SET=""
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    case "$(manifest_source "$APP" "$key")" in
      public_url)        value="https://$DOMAIN" ;;
      app_url)           value="https://$DOMAIN" ;;
      sync_store_url)    value="$SYNC_URL" ;;
      sync_store_token)  value="$APP_TOKEN" ;;
      # Set below, next to the systemd units it depends on — writing it here would
      # claim the watcher exists before it has been installed.
      update_command)    continue ;;
      *) warn "$APP/manifest.yaml: $key is derived from an unknown source; skipping"; continue ;;
    esac
    env_set "$ENV_FILE" "$key" "$value"
    DERIVED_SET="$DERIVED_SET $key"
  done < <(manifest_names_of_kind "$APP" '^derived$')
  env_protect "$ENV_FILE"
  ok "set in $ENV_FILE:$DERIVED_SET"
else
  # Stale checkout, no manifest. The original three, under the resolved prefix.
  env_set "$ENV_FILE" "${PREFIX}_PUBLIC_URL" "https://$DOMAIN"
  env_set "$ENV_FILE" "${PREFIX}_SYNC_STORE_URL" "$SYNC_URL"
  env_set "$ENV_FILE" "${PREFIX}_SYNC_STORE_TOKEN" "$APP_TOKEN"
  env_protect "$ENV_FILE"
  ok "${PREFIX}_PUBLIC_URL / _SYNC_STORE_URL / _SYNC_STORE_TOKEN set in $ENV_FILE"
fi

if [ "$APP" = "amber" ]; then
  # The voice self-update needs a host-side watcher, because there is no systemctl
  # and no Docker socket inside her container. See amber/amber-update.path.
  step "Installing the voice self-update watcher"
  run mkdir -p /var/lib/amber-infra/amber/signals
  run install -m 644 "$REPO_ROOT/amber/amber-update.path" /etc/systemd/system/amber-update.path
  run install -m 644 "$REPO_ROOT/amber/amber-update.service" /etc/systemd/system/amber-update.service
  run systemctl daemon-reload
  run systemctl enable --now amber-update.path
  env_set "$ENV_FILE" AMBER_UPDATE_COMMAND "/bin/touch /signals/update-requested"
  ok "amber-update.path armed; 'update your backend' will work by voice"
fi

# The app comes up BEFORE its site is added, which is the order ensure_sync_store
# already used and this did not.
#
# caddy_add_site ends by waiting up to 120s for https://<domain>/health. Adding the
# site first meant waiting that out against an upstream that had not been started
# yet — two minutes of certain failure, then a warning, on every single install. The
# certificate is issued when the site block appears either way; nothing needed the
# site to exist first.
step "Starting $APP"
compose_up "$APP_DIR"
wait_healthy "$APP" 120 || warn "$APP is not healthy yet — docker logs $APP --tail 100"

caddy_add_site "$APP" "$DOMAIN" "$UPSTREAM"

# Verify, don't assume. install.sh never POSTs a descriptor on the app's behalf:
# registration is agent_mcp's job on startup, and a registry entry written from bash
# would outlive the app being broken.
if [ -n "$DESCRIPTOR" ]; then
  sync_store_post_descriptor "$DESCRIPTOR" "$APP_TOKEN"
elif [ -z "$ADMIN_TOKEN" ]; then
  # Say which question could not be asked. Reporting "not registered" on the strength
  # of a request that was never authorised is the failure mode this whole change is
  # about, and repeating it here would be its own small joke.
  warn "cannot verify that '$APP' registered: there is no 'amber' entry in
     sync_store.keys, so the registry cannot be queried from this box. $APP itself is
     wired correctly. Add the key and run: bash deploy/reload-registry.sh"
else
  sync_store_wait_for_registration "$APP" 60 "$ADMIN_TOKEN" || true
fi

# ==== 5. backups =============================================================
step "Backups"
if [ ! -f /etc/cron.d/amber-infra-backup ]; then
  run install -m 644 "$REPO_ROOT/backup/backup-cron.template" /etc/cron.d/amber-infra-backup
  ok "installed /etc/cron.d/amber-infra-backup"
else
  ok "backup cron already installed"
fi
run mkdir -p /opt/amber-infra
if [ "$REPO_ROOT" != "/opt/amber-infra" ]; then
  warn "the cron file runs /opt/amber-infra/backup/*.sh but this checkout is at $REPO_ROOT.
     Either clone the repo to /opt/amber-infra or edit /etc/cron.d/amber-infra-backup."
fi
# Run one now, so "backups are configured" means "a backup exists", not "a cron
# line exists". Exits non-zero on any failure, which is the point.
if ! dry; then
  bash "$REPO_ROOT/backup/backup-sqlite.sh" || warn "the first backup run failed — fix this before you need it"
fi

# ==== 6. summary =============================================================
cat <<EOF

$(ok "$APP is installed.")

  url          https://$DOMAIN
  health       https://$DOMAIN/health
  image        $IMAGE
  env file     $ENV_FILE          (chmod 600, rendered from $SECRETS_FILE)
  compose      $APP_DIR/docker-compose.prod.yml
  caddy site   /etc/caddy/snippets/$APP.caddy

  logs         docker logs $APP -f
  restart      docker compose -f $APP_DIR/docker-compose.prod.yml up -d
  roll back    $REPO_ROOT/deploy/rollback.sh $APP --list
  discovery    curl -H "Authorization: Bearer \$TOKEN" $(sync_store_base_url)/servers

To add the next app, run this again with a different --app/--domain.
EOF
