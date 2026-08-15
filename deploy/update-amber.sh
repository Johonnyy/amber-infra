#!/usr/bin/env bash
#
# The container-era replacement for amber_v2/deploy/update.sh.
#
# Triggered two ways:
#   * by voice — Amber's update_server tool runs AMBER_UPDATE_COMMAND, which is
#     `touch /signals/update-requested`; amber-update.path sees it and starts
#     amber-update.service, which runs this.
#   * by hand — `sudo /opt/amber-infra/deploy/update-amber.sh`
#   * from Aperture — the Servers tab runs it with --dry-run first, then for real.
#
# --dry-run prints every mutating action and changes nothing, matching install.sh and
# rollback.sh. Every action a GUI can trigger has to be rehearsable, or the GUI is
# asking you to trust that it composed the flags right.
#
# What it reconciles, in order, each step idempotent:
#   sentinel   removed FIRST, so the .path unit re-arms and a failure here does not
#              wedge the trigger
#   env        new keys from the image's baked-in .env.example, defaults carried,
#              existing values never clobbered (update.sh's step 4a, host-side)
#   image      docker compose pull + up -d on the PINNED tag
#   health     wait, and REVERT to the previous image if it does not come back
#
# The revert is the point. A voice-triggered update that leaves Amber unable to
# hear the next instruction is the one failure mode that cannot fix itself.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/env.sh
. "$REPO_ROOT/install/lib/env.sh"
# shellcheck source=../install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"

AMBER_DIR="${AMBER_DIR:-/etc/amber-infra/amber}"
COMPOSE_FILE="$AMBER_DIR/docker-compose.prod.yml"
ENV_FILE="$AMBER_DIR/amber.env"
SIGNAL_DIR="${SIGNAL_DIR:-/var/lib/amber-infra/amber/signals}"
SENTINEL="$SIGNAL_DIR/update-requested"
HISTORY="/var/lib/amber-infra/deploy-history"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

require_root
[ -f "$COMPOSE_FILE" ] || die "no compose file at $COMPOSE_FILE — is Amber containerised on this box?"

# 1. Clear the sentinel first. If this script dies later, the .path unit is still
#    armed for the next request rather than stuck holding a file it already fired on.
if [ -f "$SENTINEL" ]; then
  step "Voice-triggered update request received"
  run rm -f "$SENTINEL"
fi

BEFORE="$(image_of "$COMPOSE_FILE")"
step "Updating Amber (pinned image: $BEFORE)"

# 2. Reconcile the env file against the image's baked-in example. New keys arrive
#    with their defaults; nothing already set is touched. Same contract as
#    update.sh step 4a, which is why the awk-based env_set is shared verbatim.
step "Reconciling $ENV_FILE"
EXAMPLE="$(mktemp)"
if env_example_from_image "$BEFORE" "$EXAMPLE"; then
  env_reconcile "$ENV_FILE" "$EXAMPLE" AMBER_
else
  warn "could not read .env.example from $BEFORE — skipping env reconciliation"
fi
rm -f "$EXAMPLE"

# The one check update.sh made that has no container equivalent: refuse to restart
# into a broken configuration rather than discovering it from a silent service.
env_require "$ENV_FILE" AMBER_OPENAI_API_KEY

# 3. Pull and restart on the pinned tag. `pull` on an exact tag is a no-op unless
#    the tag was force-pushed, which is exactly the semantics we want: an update
#    means "bump the pin, then run this", not "grab whatever moved".
step "Pulling and restarting"
compose "$AMBER_DIR" pull
compose "$AMBER_DIR" up -d

# 4. Health, and revert if it does not come back.
if wait_healthy amber 120; then
  ok "Amber is healthy on $BEFORE"
  dry || printf '%s\tamber\t%s\t%s\tok\n' "$(iso_now)" "$BEFORE" "$BEFORE" >> "$HISTORY"
  exit 0
fi

warn "Amber did not become healthy — reverting"
PREVIOUS="$(awk -F'\t' '$2 == "amber" && $5 == "ok" {print $4}' "$HISTORY" 2>/dev/null | tail -n2 | head -n1)"
if [ -z "$PREVIOUS" ] || [ "$PREVIOUS" = "$BEFORE" ]; then
  die "Amber is unhealthy on $BEFORE and there is no earlier known-good image to revert to.
     docker logs amber --tail 100
     deploy/rollback.sh amber --list"
fi

step "Reverting to $PREVIOUS"
dry || sed -i -E "s|^(\s*image:).*|\1 $PREVIOUS|" "$COMPOSE_FILE"
compose "$AMBER_DIR" up -d
if wait_healthy amber 120; then
  dry || printf '%s\tamber\t%s\t%s\treverted\n' "$(iso_now)" "$BEFORE" "$PREVIOUS" >> "$HISTORY"
  die "update failed; Amber has been reverted to $PREVIOUS and is healthy"
fi
die "update failed AND the revert to $PREVIOUS did not come up — docker logs amber --tail 100"
