#!/usr/bin/env bash
#
# Remove one app, or tear down the whole box.
#
#   uninstall.sh --app finance              stop it, unhook it, keep its data
#   uninstall.sh --app finance --purge      ...and delete its volumes
#   uninstall.sh --app finance --undeclare  ...and remove it from secrets.yaml too
#   uninstall.sh --all --purge --yes-i-mean-it
#   --dry-run works on every path above and changes nothing
#
# Data is kept by default and backups are NEVER touched, at any invocation. The
# --all path additionally refuses to run without --purge --yes-i-mean-it, because it
# would delete caddy-data — the ACME certificates and account key. Losing those does
# not just cost a re-issue, it spends Let's Encrypt rate limit you may need.
#
# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"
# shellcheck source=lib/caddy.sh
. "$REPO_ROOT/install/lib/caddy.sh"
# shellcheck source=lib/sync_store.sh
. "$REPO_ROOT/install/lib/sync_store.sh"

APP=""; ALL=0; PURGE=0; CONFIRMED=0; UNDECLARE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app)            APP="$2"; shift 2 ;;
    --all)            ALL=1; shift ;;
    --purge)          PURGE=1; shift ;;
    --undeclare)      UNDECLARE=1; shift ;;
    --yes-i-mean-it)  CONFIRMED=1; shift ;;
    --secrets)        SECRETS_FILE="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root

remove_app() {
  local app="$1"
  local app_dir="/etc/amber-infra/$app"

  step "Removing $app"

  caddy_remove_site "$app"

  if [ -d "$app_dir" ]; then
    if [ "$PURGE" = "1" ]; then
      compose "$app_dir" down -v
      warn "volumes for $app deleted"
    else
      compose "$app_dir" down
      ok "containers stopped; volumes kept (pass --purge to delete them)"
    fi
  fi

  # Deregister so no agent keeps trying to call something that is gone. Best effort:
  # if the store is down, the entry is stale rather than harmful — discovery fails
  # open by design.
  # Read-only: sync_store_token_for would MINT a key and write it into secrets.yaml as
  # a side effect of removing an app, which is both surprising and useless — a token
  # invented now is one the running store has never heard of, so the deregistration
  # would 401 anyway.
  local admin
  admin="$(sync_store_admin_token)"
  if [ -z "$admin" ]; then
    warn "no 'amber' entry in sync_store.keys, so '$app' cannot be deregistered from here.
     It will linger in the registry until removed by hand."
  elif sync_store_up; then
    sync_store_deregister "$app" "$admin"
  else
    warn "sync-store is not reachable — '$app' will linger in the registry until it is removed by hand"
  fi

  if [ "$app" = "amber" ]; then
    step "Disarming the voice self-update watcher"
    run systemctl disable --now amber-update.path || true
    run rm -f /etc/systemd/system/amber-update.path /etc/systemd/system/amber-update.service
    run systemctl daemon-reload
  fi

  run rm -rf "$app_dir"
  ok "$app removed. Backups under $(secrets_get '.backup.target' /var/backups/amber-infra) are untouched."
}

if [ -n "$APP" ]; then
  remove_app "$APP"
  # Strictly after remove_app, never before: it reads .backup.target and the
  # sync-store admin token out of secrets.yaml, so the stanza has to outlive the
  # teardown that uses it.
  if [ "$UNDECLARE" = "1" ]; then
    # DRY_RUN travels in the environment rather than as a flag, because common.sh
    # already reads it there and one channel cannot disagree with itself.
    DRY_RUN="$DRY_RUN" bash "$REPO_ROOT/install/declare.sh" \
      --app "$APP" --undeclare --force --secrets "$SECRETS_FILE"
  fi
  exit 0
fi

if [ "$ALL" = "1" ]; then
  if [ "$PURGE" != "1" ] || [ "$CONFIRMED" != "1" ]; then
    die "--all needs --purge --yes-i-mean-it.

     It deletes the caddy-data volume, which holds your ACME certificates and
     account key: every domain has to be re-issued, and Let's Encrypt rate-limits
     issuance per domain per week.

     To stop everything without destroying anything:
         docker stop \$(docker ps -q)"
  fi

  warn "tearing down EVERYTHING on this box"
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    [ -d "/etc/amber-infra/$app" ] || continue
    remove_app "$app"
  done < <(yq -r '.apps | keys | .[]' "$SECRETS_FILE" 2>/dev/null || true)

  step "Removing the sync-store"
  # `if`, not `[ -d x ] && cmd`: under `set -e` that form aborts the whole teardown
  # on a box that simply never had a sync-store.
  if [ -d /etc/amber-infra/sync-store ]; then
    compose /etc/amber-infra/sync-store down -v
  fi

  step "Removing the edge"
  if [ -d /etc/amber-infra/caddy ]; then
    compose /etc/amber-infra/caddy down -v
  fi

  run rm -f /etc/cron.d/amber-infra-backup
  ok "torn down. $SECRETS_FILE and $(secrets_get '.backup.target' /var/backups/amber-infra) are still here."
  exit 0
fi

die "usage: $0 --app NAME [--purge] [--undeclare] [--dry-run]
       $0 --all --purge --yes-i-mean-it [--dry-run]"
