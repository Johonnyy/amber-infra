#!/usr/bin/env bash
#
# Update the sync-store to a published tag, and put it back if it does not come up.
#
#   update-sync-store.sh                 re-pull and restart the current pin
#   update-sync-store.sh --to 0.2.0      bump the pin, then do that
#   update-sync-store.sh --to 0.2.0 --dry-run
#
# WHY THIS EXISTS. The store is the one thing in this repo that ships as a container
# image, and it was the one thing with no update path. *Update infra* is a `git pull`
# on /opt/amber-infra: it brings the source and changes nothing about what is running.
# `ensure_sync_store` returns early whenever the store is healthy and its key list is
# unchanged, so re-running install.sh never notices a new pin either. The gap was
# silent in the worst way — every app could be updated from a button, and the registry
# they all depend on could only be updated by hand, correctly, in two files.
#
# It is a thin wrapper over deploy/update-app.sh, which already does the part that
# matters: pull, restart, wait for health, and **revert to the last image this box
# actually saw healthy** if it does not come back. The store's layout is exactly what
# that script expects — /etc/amber-infra/sync-store, a docker-compose*.yml, a
# sync-store.env, a container named sync-store — and it has no manifest, so the
# required-keys step correctly checks nothing.
#
# The one thing genuinely different lives here:
#
#   **the pin exists in two places.** `sync_store.image` in secrets.yaml is what
#   install.sh reads when it first deploys the store; the deployed compose file is what
#   actually runs. `ensure_sync_store` writes the image into that compose file only on
#   the initial create, so bumping one and not the other means the next fresh install
#   silently rolls the registry backwards. This writes secrets.yaml too — but only
#   AFTER the update has succeeded, so a version that was rejected and reverted never
#   ends up recorded as the one this box wants.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=../install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"

SYNC_STORE_DIR="${SYNC_STORE_DIR:-/etc/amber-infra/sync-store}"

TO=""
PASS_THROUGH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to)      TO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; PASS_THROUGH+=("--dry-run"); shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

require_root

COMPOSE_FILE="$(find "$SYNC_STORE_DIR" -maxdepth 1 -name 'docker-compose*.yml' 2>/dev/null | sort | head -n1 || true)"
[ -n "$COMPOSE_FILE" ] || die "the sync-store is not deployed on this box (nothing under $SYNC_STORE_DIR).
     It is brought up by install.sh on a box whose role is 'core'."

CURRENT="$(image_of "$COMPOSE_FILE")"
PINNED="$(secrets_get '.sync_store.image')"

# A tag, or a whole reference — the GUI may pass either the release tag it read from
# GitHub or the full image it read from this box.
if [ -n "$TO" ]; then
  case "$TO" in
    *:*) TARGET="$TO" ;;
    *)   TARGET="${CURRENT%:*}:${TO#v}" ;;
  esac
else
  TARGET="$CURRENT"
fi

# Said before anything happens, because it is the one piece of state a reader cannot
# see from either file on its own.
if [ -n "$PINNED" ] && [ "$PINNED" != "$CURRENT" ]; then
  warn "secrets.yaml pins $PINNED but the deployed compose runs $CURRENT.
     They will agree again when this finishes."
fi

step "Updating the sync-store to $TARGET (running: $CURRENT)"

UPDATE_ARGS=()
[ "$TARGET" != "$CURRENT" ] && UPDATE_ARGS+=("--to" "$TARGET")
bash "$REPO_ROOT/deploy/update-app.sh" sync-store "${UPDATE_ARGS[@]}" "${PASS_THROUGH[@]}"

# Only reached when the update succeeded: update-app.sh dies on failure — including
# after a successful revert — and `set -e` stops us here.
if [ "$PINNED" != "$TARGET" ]; then
  step "Recording the pin in $SECRETS_FILE (was ${PINNED:-unset})"
  secrets_set '.sync_store.image' "$TARGET"
fi

ok "the sync-store is on $TARGET, and secrets.yaml agrees"
echo "     Every app reads this registry; nothing else needs restarting."
