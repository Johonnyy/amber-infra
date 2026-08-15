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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=install/lib/env.sh
. "$REPO_ROOT/install/lib/env.sh"
# shellcheck source=install/lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"
# shellcheck source=install/lib/caddy.sh
. "$REPO_ROOT/install/lib/caddy.sh"
# shellcheck source=install/lib/sync_store.sh
. "$REPO_ROOT/install/lib/sync_store.sh"
# shellcheck source=install/lib/preflight.sh
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

     Fill in every CHANGEME (generate each with: openssl rand -hex 32), set
     infra.acme_email and infra.primary_domain, then re-run this command.

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
if [ "$ROLE" = "core" ]; then
  ensure_sync_store
  caddy_add_site sync-store "sync.$(secrets_get '.infra.primary_domain')" \
      "127.0.0.1:$(secrets_get '.sync_store.port' 8081)"
fi

step "Wiring $APP into the sync-store"
APP_TOKEN="$(sync_store_token_for "$APP")"
SYNC_URL="$(secrets_require '.sync_store.url')"

# Amber owns a single AMBER_ prefix for three consumers (herself, agent_runtime,
# agent_mcp) and constructs both libraries' settings from it with _env_file=None —
# AGENT_MCP_* keys in her env file would be silently ignored. Every other app is a
# plain agent-mcp-py consumer and reads AGENT_MCP_*.
if [ "$APP" = "amber" ]; then
  PREFIX="AMBER_MCP"
else
  PREFIX="AGENT_MCP"
fi
env_set "$ENV_FILE" "${PREFIX}_PUBLIC_URL" "https://$DOMAIN"
env_set "$ENV_FILE" "${PREFIX}_SYNC_STORE_URL" "$SYNC_URL"
env_set "$ENV_FILE" "${PREFIX}_SYNC_STORE_TOKEN" "$APP_TOKEN"
env_protect "$ENV_FILE"
ok "${PREFIX}_PUBLIC_URL / _SYNC_STORE_URL / _SYNC_STORE_TOKEN set in $ENV_FILE"

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

caddy_add_site "$APP" "$DOMAIN" "$UPSTREAM"

step "Starting $APP"
compose_up "$APP_DIR"
wait_healthy "$APP" 120 || warn "$APP is not healthy yet — docker logs $APP --tail 100"

# Verify, don't assume. install.sh never POSTs a descriptor on the app's behalf:
# registration is agent_mcp's job on startup, and a registry entry written from bash
# would outlive the app being broken.
ADMIN_TOKEN="$(sync_store_token_for amber)"
if [ -n "$DESCRIPTOR" ]; then
  sync_store_post_descriptor "$DESCRIPTOR" "$APP_TOKEN"
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
