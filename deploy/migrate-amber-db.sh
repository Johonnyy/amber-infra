#!/usr/bin/env bash
#
# Move Amber from the systemd deploy at /opt/amber onto the container + volume.
#
# Run ONCE, as root, on the OVH box. Idempotent: it refuses if the volume already
# holds a database, unless --force.
#
# THE REASON THIS IS A SCRIPT AND NOT A `cp`: amber.db is WAL-mode SQLite with three
# co-tenant writers — Amber's memory store, agent_mcp_usage and
# agent_runtime_usage all share the file by agreement (WAL + busy_timeout). A plain
# copy takes the main database file while committed data is still sitting in a -wal
# file you did not copy. `sqlite3 .backup` uses the online backup API and produces a
# consistent snapshot of a live database.
#
# It is also deliberately NON-DESTRUCTIVE: /opt/amber and its unit are left in place,
# disabled but intact, so the rollback is `systemctl start amber`. Delete them when
# you have had a good day on the container, not before.
#
# Usage:
#   sudo bash /opt/amber-infra/deploy/migrate-amber-db.sh [--force] [--dry-run]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

OLD_DB="${OLD_DB:-/opt/amber/amber.db}"
VOLUME="${VOLUME:-amber-data}"
AMBER_DIR="${AMBER_DIR:-/etc/amber-infra/amber}"

require_root
require_cmd sqlite3
[ -f "$OLD_DB" ] || die "no database at $OLD_DB — nothing to migrate (is Amber deployed here?)"
[ -f "$AMBER_DIR/docker-compose.prod.yml" ] || die "run install.sh --app amber first; $AMBER_DIR is not set up"

# --- 0. refuse to clobber ----------------------------------------------------
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if docker run --rm -v "$VOLUME":/data alpine test -f /data/amber.db 2>/dev/null; then
    [ "$FORCE" = "1" ] || die "$VOLUME already contains amber.db — pass --force only if you mean to overwrite it"
    warn "--force given: the existing database in $VOLUME will be overwritten"
  fi
fi

BEFORE_FACTS="$(sqlite3 "$OLD_DB" 'SELECT count(*) FROM facts' 2>/dev/null || echo '?')"
BEFORE_CONVS="$(sqlite3 "$OLD_DB" 'SELECT count(*) FROM conversations' 2>/dev/null || echo '?')"
step "Migrating $OLD_DB ($BEFORE_FACTS facts, $BEFORE_CONVS conversations)"

# --- 1. stop the systemd service --------------------------------------------
# A snapshot of a database still being written to is valid, but starting the
# container against a volume while the old service also holds the file is not.
if systemctl is-active --quiet amber 2>/dev/null; then
  step "Stopping the systemd service"
  run systemctl stop amber
  ok "amber.service stopped (left enabled — this is the rollback)"
else
  ok "amber.service is not running"
fi

# --- 2. consistent snapshot --------------------------------------------------
step "Snapshotting with sqlite3 .backup (NOT cp — this file is WAL with three writers)"
SNAP="$(mktemp /tmp/amber-migrate-XXXXXX.db)"
if dry; then
  echo "   ${c_yellow}dry-run${c_off} would snapshot $OLD_DB"
else
  sqlite3 "$OLD_DB" ".backup '$SNAP'"
fi

# --- 3. verify BEFORE trusting it -------------------------------------------
if ! dry; then
  step "Verifying the snapshot"
  [ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check' | head -n1)" = "ok" ] \
    || die "integrity_check FAILED on the snapshot — the original at $OLD_DB is untouched, nothing has moved"
  SNAP_FACTS="$(sqlite3 "$SNAP" 'SELECT count(*) FROM facts' 2>/dev/null || echo '?')"
  [ "$SNAP_FACTS" = "$BEFORE_FACTS" ] \
    || die "the snapshot has $SNAP_FACTS facts but the original has $BEFORE_FACTS — refusing to continue"
  ok "integrity_check ok, $SNAP_FACTS facts carried"
fi

# --- 4. into the volume ------------------------------------------------------
step "Copying into the $VOLUME volume"
run docker volume create "$VOLUME" >/dev/null
if ! dry; then
  docker run --rm -v "$VOLUME":/data -v "$(dirname "$SNAP")":/src alpine \
    sh -c "cp /src/$(basename "$SNAP") /data/amber.db && chown 10002:10002 /data/amber.db"
fi
rm -f "$SNAP"
ok "database is in $VOLUME:/data/amber.db"

# --- 5. start the container --------------------------------------------------
step "Starting the container"
compose_up "$AMBER_DIR"
wait_healthy amber 120 || die "the container did not become healthy.
     Your data is safe: $OLD_DB is untouched and amber.service is still installed.
     Roll back with:  systemctl start amber
     Then:            docker logs amber --tail 100"

if ! dry; then
  AFTER_FACTS="$(docker exec amber sqlite3 /data/amber.db 'SELECT count(*) FROM facts' 2>/dev/null || echo '?')"
  [ "$AFTER_FACTS" = "$BEFORE_FACTS" ] \
    || warn "fact count differs after migration: $BEFORE_FACTS -> $AFTER_FACTS"
fi

cat <<EOF

$(ok "Migration complete.")

Verify the parts a health check cannot:
  1. A real voice turn through the proxy — this is what proves Caddy's
     flush_interval is right and the WebSocket survives the edge:
       python scripts/smoke_client.py path/to/utterance.wav   (against wss://<domain>/ws)
  2. Her memory came with her — ask her something she knew yesterday.
  3. The voice self-update: say "update your backend", then
       journalctl -u amber-update -f

NOT done, deliberately:
  * /opt/amber is still there and amber.service is still enabled (just stopped).
    That is your rollback: systemctl start amber.
  * Run 'systemctl disable amber' and remove /opt/amber only after a good day on
    the container.
EOF
