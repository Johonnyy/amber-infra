#!/usr/bin/env bash
#
# Make the running sync-store agree with secrets.yaml, and say what changed.
#
# THE PROBLEM THIS EXISTS FOR: the store reads SYNC_STORE_KEYS once, at container
# startup (sync-store/app/main.py builds its key list inside build_app(), which runs
# at import). A token minted after it last started is one it has never heard of, so
# every registration attempt from that app is a 401 — and agent_mcp's register()
# swallows failures by contract, so nothing anywhere says so. The app is healthy, its
# container is healthy, and it is simply absent from the registry forever.
#
# Re-running install.sh for the app fixes it as a side effect. That is a large hammer
# for one nail, needs the app's domain and upstream to hand, and pulls images. This is
# the nail on its own.
#
# It is deliberately a thin wrapper: the reconciliation logic is ensure_sync_store in
# install/lib/sync_store.sh, which already compares the rendered key list against
# secrets.yaml and force-recreates ONLY when it actually changed. Restarting a healthy
# registry on every invocation would be its own small outage, repeated.
#
# Safe to run at any time. When nothing has drifted it changes nothing and says so.
#
# Usage:
#   sudo bash /opt/amber-infra/deploy/reload-registry.sh [--dry-run]
#
# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"
# shellcheck source=../install/lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=../install/lib/sync_store.sh
. "$REPO_ROOT/install/lib/sync_store.sh"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_root
require_cmd yq
secrets_check

# The store lives on the core box. On a `role: app` box this script would render a key
# list into a directory nothing reads and restart a container that is not here, so
# refuse rather than appear to have fixed something.
ROLE="$(secrets_get '.infra.role' core)"
if [ "$ROLE" != "core" ]; then
  die "this box is role: $ROLE — the sync-store runs on the core box, so run this there.
     The keys an app on this box uses must exist in the CORE box's secrets.yaml."
fi

# --- what it looks like now --------------------------------------------------
# Names only. The point of the before/after is which keys the store knows about, and
# printing a token to a terminal puts it in scrollback and in whatever captured it.

keys_named() {  # the name halves of SYNC_STORE_KEYS, one per line
  printf '%s' "${1:-}" | tr ',' '\n' | sed -e 's/:.*$//' -e '/^[[:space:]]*$/d'
}

BEFORE=""
if [ -f "$SYNC_STORE_DIR/sync-store.env" ]; then
  BEFORE="$(env_get "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_KEYS || true)"
fi

step "The registry's key list"
if [ -n "$BEFORE" ]; then
  echo "   running: $(keys_named "$BEFORE" | paste -sd' ' -)"
else
  echo "   running: (the store has not been deployed here yet)"
fi
echo "   declared: $(keys_named "$(secrets_sync_store_keys)" | paste -sd' ' -)"

# --- reconcile the file ------------------------------------------------------
# Renders sync-store.env from secrets.yaml and force-recreates if THAT file changed.

ensure_sync_store

# --- reconcile the container -------------------------------------------------
# The case ensure_sync_store cannot see, and the reason this script is not just a
# call to it: the env file was already correct and the CONTAINER is not. That happens
# whenever the file was written by a run that then failed, or by an older install.sh,
# or when compose declined to recreate — and it presents identically to everything
# else, because the file you would go and read is right.
#
# `docker container inspect` rather than the file: compose materialises env_file into
# Config.Env when the container is CREATED, so this is the list the store is actually
# checking against. It also answers for a stopped container, which is when you most
# want to know.

sync_keys_digest() {  # digest of a key list, or "" when nothing here can hash
  if   have sha256sum; then printf '%s' "$1" | sha256sum     | cut -c1-12
  elif have shasum;    then printf '%s' "$1" | shasum -a 256 | cut -c1-12
  elif have openssl;   then printf '%s' "$1" | openssl dgst -sha256 -r | cut -c1-12
  fi
}

WANT="$(sync_keys_digest "$(secrets_sync_store_keys)")"
RUNNING="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sync-store 2>/dev/null \
  | sed -n 's/^SYNC_STORE_KEYS=//p' | head -n1 || true)"
HAVE="$(sync_keys_digest "$RUNNING")"
unset RUNNING

if [ -z "$WANT" ]; then
  warn "no sha256 tool on this box, so the running container's key list cannot be
     compared. ensure_sync_store above still reconciled the env file."
elif [ -z "$HAVE" ]; then
  warn "the sync-store container has no SYNC_STORE_KEYS in its environment.
     It will reject every request. Check: docker logs sync-store --tail 50"
elif [ "$WANT" = "$HAVE" ]; then
  ok "the running container is checking against the current key list ($WANT)"
else
  step "The container is running an older key list ($HAVE, want $WANT) — recreating it"
  # `sync-store-data` is a named volume, so recreating the container keeps the
  # database. A few seconds of 502 for in-flight heartbeats is the entire cost, and
  # a heartbeat that misses simply retries.
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would: compose $SYNC_STORE_DIR up -d --force-recreate"
  else
    compose "$SYNC_STORE_DIR" up -d --force-recreate
    wait_healthy sync-store 90 || die "sync-store did not come back — docker logs sync-store --tail 50"
    ok "reloaded"
  fi
fi

# --- confirm -----------------------------------------------------------------
# Ask the store what it now believes, rather than asserting it. A reload that came
# back healthy but rejects amber's own token is exactly the failure this is here to
# end, so the check is worth the one extra request.

if dry; then
  ok "dry run: nothing was changed"
  exit 0
fi

ADMIN_TOKEN="$(yq -r '.sync_store.keys[]? | select(.name == "amber") | .token' "$SECRETS_FILE" 2>/dev/null | head -n1)"
case "$ADMIN_TOKEN" in null) ADMIN_TOKEN="" ;; esac

if [ -z "$ADMIN_TOKEN" ]; then
  warn "no 'amber' entry in sync_store.keys, so the registry cannot be queried to confirm.
     The reload above still applied. Add one and re-run install.sh to be able to read it."
  exit 0
fi

step "What is registered now"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
CODE="$(curl -s -o "$BODY" -m 6 -w '%{http_code}' \
  -H "Authorization: Bearer $ADMIN_TOKEN" "$(sync_store_base_url)/servers" 2>/dev/null || true)"

case "$CODE" in
  200)
    if have jq; then
      NAMES="$(jq -r '(.servers // .) | map(.name) | join(" ")' "$BODY" 2>/dev/null || true)"
    else
      NAMES="$(tr ',' '\n' <"$BODY" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | paste -sd' ' -)"
    fi
    if [ -n "$NAMES" ]; then
      ok "registered: $NAMES"
    else
      ok "the registry is empty — nothing has checked in yet"
    fi
    # Registration is on startup and then every 300s, so an app whose key was just
    # added will not appear here for up to five minutes. Say so once, here, rather
    # than letting it read as a failure.
    echo "   An app whose key was just added registers on its next startup or heartbeat"
    echo "   (up to 5 minutes). To have it now:  docker restart <app>"
    ;;
  401)
    die "the store came back healthy but rejects amber's token.
     That means the reload did not take: the container is still running an older
     SYNC_STORE_KEYS. Force it:
         docker compose -f $SYNC_STORE_DIR/docker-compose.prod.yml up -d --force-recreate"
    ;;
  *)
    warn "the store did not answer GET /servers (${CODE:-no response}). The key list was
     reloaded regardless. Check: docker logs sync-store --tail 50"
    ;;
esac
