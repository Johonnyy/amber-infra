#!/usr/bin/env bash
#
# Update one app to a pinned tag, and put it back if it does not come up.
#
#   update-app.sh amber                     re-pull and restart the current pin
#   update-app.sh bloom --to 0.3.1          bump the pin, then do that
#   update-app.sh amber --dry-run           print every mutating action, change nothing
#
# Generalised from update-amber.sh, which stays as a thin wrapper because the systemd
# path unit and Amber's own voice tool both name it.
#
# **The revert is the point.** Anything else here could be done with two docker
# commands; reverting to the last image this box actually saw healthy is what makes
# "Update" safe to put behind a single button. A voice-triggered update that leaves
# Amber unable to hear the next instruction is the one failure that cannot fix itself,
# and the same is true of a GUI-triggered one on a box you are not sitting at.
#
# What it does, in order, each step idempotent:
#   sentinel   cleared FIRST, so a failure here does not wedge the .path trigger
#   baseline   the running image is recorded as known-good if the box can see it is,
#              which is what arms the revert on an app's very first update
#   pin        rewritten only when --to was given, and never to a floating tag
#   env        new keys from the image's baked-in .env.example, defaults carried,
#              existing values never clobbered
#   require    every key the manifest says is required must hold a real value
#   image      docker compose pull + up -d on the PINNED tag
#   health     wait, and REVERT to the previous known-good image if it does not return
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/env.sh
. "$REPO_ROOT/install/lib/env.sh"
# shellcheck source=../install/lib/docker.sh
. "$REPO_ROOT/install/lib/docker.sh"
# shellcheck source=../install/lib/manifest.sh
. "$REPO_ROOT/install/lib/manifest.sh"

APP=""; TO=""; ENV_PREFIX=""; OPTIONAL=""; TIMEOUT=120
HISTORY="/var/lib/amber-infra/deploy-history"

usage() {
  cat <<'USAGE'
usage: update-app.sh APP [options]

  --to TAG           bump the pinned image to TAG first (never a floating tag)
  --env-prefix P     only reconcile keys starting with P from the image's example
  --optional KEY     do not require KEY, even if the manifest does (repeatable)
  --timeout N        seconds to wait for health (default 120)
  --dry-run          print what would happen and change nothing
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to)          TO="$2"; shift 2 ;;
    --env-prefix)  ENV_PREFIX="$2"; shift 2 ;;
    --optional)    OPTIONAL="$OPTIONAL $2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    -*)            die "unknown argument: $1" ;;
    *)             [ -z "$APP" ] || die "only one app at a time"; APP="$1"; shift ;;
  esac
done

[ -n "$APP" ] || usage
require_root

APP_DIR="/etc/amber-infra/$APP"
COMPOSE_FILE="$(find "$APP_DIR" -maxdepth 1 -name 'docker-compose*.yml' 2>/dev/null | sort | head -n1 || true)"
ENV_FILE="$APP_DIR/$APP.env"
[ -n "$COMPOSE_FILE" ] || die "no compose file under $APP_DIR — is '$APP' installed on this box?"

# 1. Clear the sentinel first, so that if this script dies later the .path unit is
#    armed for the next request rather than stuck holding a file it already fired on.
#    Only Amber has one; the loop is here so the next app to grow one needs no change.
SENTINEL="${SIGNAL_DIR:-/var/lib/amber-infra/$APP/signals}/update-requested"
if [ -f "$SENTINEL" ]; then
  step "Update request received via $SENTINEL"
  run rm -f "$SENTINEL"
fi

BEFORE="$(image_of "$COMPOSE_FILE")"

# 1b. Arm the revert.
#
# `$HISTORY` only ever gained a row from a *successful* update through this script,
# and nothing in install/ writes one — so on the first update of a freshly installed
# app there was no known-good image, the revert below refused with "nothing to revert
# to", and the box was left sitting on the broken pin. That is the exact update where
# the net matters most: nobody has yet watched this app survive a deploy.
#
# So the baseline is what is *running right now*, recorded before anything is pulled
# or rewritten, and only when the box can see for itself that it is good. "Good" is
# wait_healthy's own definition, so the thing that arms the revert and the thing that
# triggers it cannot disagree.
run mkdir -p "$(dirname "$HISTORY")"
if ! dry && [ -n "$BEFORE" ]; then
  BASELINE=0
  # `if` rather than `[ … ] && …` as the last command of a branch: under `set -e` a
  # false test there makes the whole `case` exit non-zero and takes the script with it.
  case "$(container_health "$APP")" in
    healthy) BASELINE=1 ;;
    none)    if [ "$(container_state "$APP")" = "running" ]; then BASELINE=1; fi ;;
  esac
  # Read as "this box saw $APP healthy on this image", which is exactly what the
  # revert below looks for and what `rollback.sh --list` should show.
  if [ "$BASELINE" = "1" ] \
     && ! awk -F'\t' -v a="$APP" -v i="$BEFORE" '$2 == a && $4 == i && $5 == "ok"' \
          "$HISTORY" 2>/dev/null | grep -q .; then
    printf '%s\t%s\t%s\t%s\tok\n' "$(iso_now)" "$APP" "$BEFORE" "$BEFORE" >> "$HISTORY"
  fi
fi

# 2. The new pin, if one was asked for.
if [ -n "$TO" ]; then
  # A tag, or a whole reference. Accepting both means the GUI can pass either the
  # release tag it read from GitHub or the full image it read from the compose file.
  case "$TO" in
    *:*) TARGET="$TO" ;;
    *)   TARGET="${BEFORE%:*}:${TO#v}" ;;
  esac
  case "$TARGET" in
    *:latest|*:stable)
      die "refusing to pin $APP to a moving tag ($TARGET).
     A restart must never change the code. Pass an explicit version." ;;
  esac
  if [ "$TARGET" != "$BEFORE" ]; then
    step "Pinning $APP to $TARGET (was $BEFORE)"
    # Checked before the pin is written, so a typo'd tag leaves the file alone rather
    # than pinning to something that does not exist and failing at `up`.
    if ! dry; then
      docker pull "$TARGET" >/dev/null 2>&1 || die "cannot pull $TARGET — is that tag published?"
      sed -i -E "s|^(\s*image:).*|\1 $TARGET|" "$COMPOSE_FILE"
    else
      echo "   ${c_yellow}dry-run${c_off} would pull $TARGET and rewrite the pin"
    fi
  fi
fi

AFTER="$(image_of "$COMPOSE_FILE")"
dry && [ -n "$TO" ] && AFTER="$TARGET"
step "Updating $APP (pinned image: $AFTER)"

# 3. Reconcile the env file against the image's baked-in example. New keys arrive with
#    their defaults; nothing already set is touched.
step "Reconciling $ENV_FILE"
EXAMPLE="$(mktemp)"
if env_example_from_image "$AFTER" "$EXAMPLE"; then
  env_reconcile "$ENV_FILE" "$EXAMPLE" "$ENV_PREFIX"
else
  # Not every image bakes one — the sync-store does not. Skipping costs new keys
  # arriving with their defaults; it does not weaken the required-values check below,
  # which is the one that must refuse to restart into a broken configuration.
  warn "no /srv/.env.example in $AFTER — skipping env reconciliation.
     New keys will not arrive with defaults; existing values are untouched."
fi
rm -f "$EXAMPLE"

# 4. Refuse to restart into a broken configuration rather than discovering it from a
#    silent service. `env_require` rejects unset, CHANGEME and `...` alike.
#
#    Driven by the manifest instead of a hand-kept list per app. The list is exactly
#    the keys the app said only a human can supply — a `generated:*` key is the box's
#    job and a `derived` one is install.sh's, so neither belongs in a check whose
#    failure message is "go and find this value".
REQUIRE=""
while IFS= read -r key; do
  [ -z "$key" ] && continue
  manifest_is_required "$APP" "$key" || continue
  case " $OPTIONAL " in *" $key "*) continue ;; esac
  REQUIRE="$REQUIRE $key"
done < <(manifest_names_of_kind "$APP" '^supplied$')

if [ -n "$REQUIRE" ]; then
  step "Checking required values"
  # shellcheck disable=SC2086
  # Word splitting is intended: env_require takes a list of key names.
  env_require "$ENV_FILE" $REQUIRE
  ok "present:$REQUIRE"
fi

# 5. Pull and restart on the pinned tag. `pull` on an exact tag is a no-op unless the
#    tag was force-pushed, which is the semantics we want: an update means "bump the
#    pin, then run this", never "grab whatever moved".
step "Pulling and restarting"
compose "$APP_DIR" pull
compose "$APP_DIR" up -d

# 6. Health, and revert if it does not come back.
if wait_healthy "$APP" "$TIMEOUT"; then
  ok "$APP is healthy on $AFTER"
  dry || printf '%s\t%s\t%s\t%s\tok\n' "$(iso_now)" "$APP" "$BEFORE" "$AFTER" >> "$HISTORY"
  exit 0
fi

warn "$APP did not become healthy — reverting"
# The last image this box actually saw healthy, which is not the same as "the previous
# line": a failed update writes no `ok` row, so repeated failures keep pointing at the
# same known-good image rather than walking backwards one bad deploy at a time.
PREVIOUS="$(awk -F'\t' -v a="$APP" '$2 == a && $5 == "ok" {print $4}' "$HISTORY" 2>/dev/null \
  | grep -v "^$AFTER\$" | tail -n1)"
if [ -z "$PREVIOUS" ]; then
  # Reachable only when the box has never seen this app healthy — including just
  # before this run, since step 1b records that. So there is genuinely nowhere to go
  # back to, and the compose file is still pinned to $AFTER: say both, because the
  # state the box is left in is the part that matters to whoever reads this.
  die "$APP is unhealthy on $AFTER and this box has never seen it healthy on any image,
     so there is nothing to revert to. It is still pinned to $AFTER.
     The last log lines are above. Then:
     deploy/rollback.sh $APP --list"
fi

step "Reverting to $PREVIOUS"
dry || sed -i -E "s|^(\s*image:).*|\1 $PREVIOUS|" "$COMPOSE_FILE"
compose "$APP_DIR" up -d
if wait_healthy "$APP" "$TIMEOUT"; then
  dry || printf '%s\t%s\t%s\t%s\treverted\n' "$(iso_now)" "$APP" "$AFTER" "$PREVIOUS" >> "$HISTORY"
  die "update failed; $APP has been reverted to $PREVIOUS and is healthy"
fi
die "update failed AND the revert to $PREVIOUS did not come up — docker logs $APP --tail 100"
