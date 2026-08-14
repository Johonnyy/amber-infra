#!/usr/bin/env bash
#
# Roll a containerised service back to an earlier pinned image.
#
# The one property this script must have: it must never leave you worse off than
# before you ran it. So it backs up the compose file, and if the target tag does not
# become healthy it puts the old one back and brings that up again before failing.
#
# The previous image is still on disk, which is what makes this fast and offline —
# and is why WATCHTOWER_CLEANUP is off on Server A. Cleaning up old images saves a
# few hundred megabytes and costs you your rollback.
#
# Usage:
#   rollback.sh <service> [tag]     roll to TAG, or to the previous known-good
#   rollback.sh <service> --list    tags on disk plus the deploy journal
#   rollback.sh <service> <tag> --yes   skip the confirmation
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/install/lib/common.sh"
. "$REPO_ROOT/install/lib/docker.sh"

HISTORY="/var/lib/amber-infra/deploy-history"

SERVICE=""; TAG=""; LIST=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --list)    LIST=1 ;;
    --yes|-y)  YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*)        die "unknown flag: $arg" ;;
    *)         if [ -z "$SERVICE" ]; then SERVICE="$arg"; else TAG="$arg"; fi ;;
  esac
done

[ -n "$SERVICE" ] || die "usage: $0 <service> [tag] [--list] [--yes]"

SERVICE_DIR="/etc/amber-infra/$SERVICE"
COMPOSE_FILE="$(ls "$SERVICE_DIR"/docker-compose*.yml 2>/dev/null | head -n1 || true)"
[ -n "$COMPOSE_FILE" ] || die "no compose file under $SERVICE_DIR — is '$SERVICE' deployed here?"

CURRENT="$(image_of "$COMPOSE_FILE")"
REPOSITORY="${CURRENT%:*}"

if [ "$LIST" = "1" ]; then
  step "Images on disk for $REPOSITORY"
  docker image ls --format '  {{.Tag}}\t{{.CreatedSince}}\t{{.Size}}' "$REPOSITORY" 2>/dev/null \
    || warn "no local images for $REPOSITORY"
  echo
  step "Deploy journal ($HISTORY)"
  if [ -f "$HISTORY" ]; then
    awk -F'\t' -v s="$SERVICE" '$2 == s {printf "  %s  %s -> %s  [%s]\n", $1, $3, $4, $5}' "$HISTORY" | tail -n 20
  else
    warn "no journal yet"
  fi
  echo
  ok "currently pinned: $CURRENT"
  exit 0
fi

# No tag given: the previous known-good from the journal.
if [ -z "$TAG" ]; then
  PREV_IMAGE="$(awk -F'\t' -v s="$SERVICE" '$2 == s && $5 == "ok" {print $4}' "$HISTORY" 2>/dev/null \
                 | grep -v "^${CURRENT}$" | tail -n1 || true)"
  [ -n "$PREV_IMAGE" ] || die "no earlier known-good image for $SERVICE in the journal — pass a tag explicitly ($0 $SERVICE --list)"
  TAG="${PREV_IMAGE##*:}"
fi

TARGET="$REPOSITORY:$TAG"
[ "$TARGET" != "$CURRENT" ] || die "$SERVICE is already on $TARGET"

step "Rolling $SERVICE back: $CURRENT -> $TARGET"
if [ "$YES" != "1" ] && ! dry; then
  confirm "Proceed?" || die "aborted"
fi

BACKUP="$(mktemp)"
cp "$COMPOSE_FILE" "$BACKUP"

# Rewrite ONLY the image line. A templated regeneration would discard whatever hand
# edit is the reason someone is rolling back at 2am.
if ! dry; then
  sed -i -E "s|^(\s*image:\s*)[^[:space:]]+|\1$TARGET|" "$COMPOSE_FILE"
fi

compose "$SERVICE_DIR" up -d

if wait_healthy "$SERVICE" 90; then
  run mkdir -p "$(dirname "$HISTORY")"
  dry || printf '%s\t%s\t%s\t%s\tok\n' "$(iso_now)" "$SERVICE" "$CURRENT" "$TARGET" >> "$HISTORY"
  rm -f "$BACKUP"
  ok "$SERVICE is healthy on $TARGET"
  exit 0
fi

warn "$TARGET did not become healthy — restoring $CURRENT"
cp "$BACKUP" "$COMPOSE_FILE"
rm -f "$BACKUP"
compose "$SERVICE_DIR" up -d
if wait_healthy "$SERVICE" 90; then
  dry || printf '%s\t%s\t%s\t%s\treverted\n' "$(iso_now)" "$SERVICE" "$CURRENT" "$TARGET" >> "$HISTORY"
  die "rollback to $TARGET failed; $SERVICE is back on $CURRENT and healthy"
fi
die "rollback to $TARGET failed AND $CURRENT did not come back up — docker logs $SERVICE --tail 100"
