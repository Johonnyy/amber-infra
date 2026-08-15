#!/usr/bin/env bash
#
# Write an app's stanza into secrets.yaml, from its manifest.
#
#   declare.sh --app bloom --domain bloom.example.com
#   declare.sh --app bloom --reconcile            # bring an existing stanza up to date
#   declare.sh --app bloom --reconcile --adopt    # ...and rename wrong-prefix keys
#   declare.sh --app bloom --undeclare            # remove it
#
# Config only. Nothing is deployed, nothing is pulled, no container is touched — this
# is the half of "install" you might want without the other half, because declaring an
# app for server B from server A is a normal thing to do.
#
# Why this exists as a script rather than as `yq` calls in Aperture: it was the GUI
# that knew how a stanza is spelled, including which prefix to use, and it guessed —
# a hardcoded `{amber: AMBER_MCP, bloom: BLOOM_MCP}` map plus a free-text field the
# user could mistype. Every spelling decision now lives here, next to the manifest
# that decides it, in one language.
#
# Idempotent throughout. Re-running is reconcile: an existing value is never
# overwritten, so this is safe to run against a live box to fill in what is missing.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=lib/secrets.sh
. "$REPO_ROOT/install/lib/secrets.sh"
# shellcheck source=lib/manifest.sh
. "$REPO_ROOT/install/lib/manifest.sh"

APP=""; DOMAIN=""; UPSTREAM=""; IMAGE=""; SERVER=""
RECONCILE=0; ADOPT=0; UNDECLARE=0; FORCE=0

usage() {
  cat <<'USAGE'
usage: declare.sh --app NAME [options]

  --app NAME         the app, which must have a manifest.yaml in this checkout
  --domain FQDN      the hostname Caddy will serve it on
  --upstream H:P     defaults to the loopback binding in its compose file
  --image REF        defaults to the pinned image in its compose file
  --server LABEL     which box it belongs to; defaults to infra.server
  --reconcile        update an existing stanza instead of refusing
  --adopt            with --reconcile, rename keys that carry the wrong prefix
  --undeclare        remove the stanza and its sync-store key
  --force            with --undeclare, skip the still-deployed check (the caller
                     is sequencing the uninstall itself)
  --secrets FILE     operate on FILE instead of /etc/amber-infra/secrets.yaml
  --dry-run          print what would change
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)        APP="$2"; shift 2 ;;
    --domain)     DOMAIN="$2"; shift 2 ;;
    --upstream)   UPSTREAM="$2"; shift 2 ;;
    --image)      IMAGE="$2"; shift 2 ;;
    --server)     SERVER="$2"; shift 2 ;;
    --reconcile)  RECONCILE=1; shift ;;
    --adopt)      ADOPT=1; shift ;;
    --undeclare)  UNDECLARE=1; shift ;;
    --force)      FORCE=1; shift ;;
    --secrets)    SECRETS_FILE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$APP" ] || usage
secrets_check

APP_PATH=".apps.\"$APP\""
EXISTS=0
[ "$(yq -r "$APP_PATH // \"\"" "$SECRETS_FILE")" = "" ] || EXISTS=1

# ==== undeclare ==============================================================
#
# Deliberately separate from uninstall.sh, and deliberately ordered after it when
# both run: remove_app reads .backup.target and the sync-store admin token out of
# this file, so the stanza has to outlive the teardown.
if [ "$UNDECLARE" = "1" ]; then
  [ "$EXISTS" = "1" ] || { ok "'$APP' is not declared in $SECRETS_FILE — nothing to do"; exit 0; }
  # Skipped when the caller owns the ordering — uninstall.sh --undeclare has already
  # run remove_app by the time it gets here, and Aperture's composed Remove is one
  # operation that does both. Without this they would have to race their own guard.
  if [ "$FORCE" != "1" ] && { [ -d "/etc/amber-infra/$APP" ] || docker inspect "$APP" >/dev/null 2>&1; }; then
    die "'$APP' still looks deployed on this box.
     Removing its declaration now would leave a container, /etc/amber-infra/$APP and a
     Caddy site answering to a name nothing describes. Run
     install/uninstall.sh --app $APP first."
  fi
  step "Removing the declaration for $APP"
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would delete $APP_PATH and its sync_store.keys entry"
  else
    yq -i "del($APP_PATH)" "$SECRETS_FILE"
    # The registry key too. Leaving it behind means a bearer token for an app that no
    # longer exists stays valid in sync-store's key list.
    yq -i "del(.sync_store.keys[] | select(.name == \"$APP\"))" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi
  ok "$APP undeclared. Its backups are untouched."
  exit 0
fi

# ==== declare / reconcile ====================================================
manifest_have "$APP" || die "no $APP/manifest.yaml in this checkout.
     An app is declarable when it says what it needs. Add the manifest beside its
     docker-compose.prod.yml — model it on amber/manifest.yaml."

if [ "$EXISTS" = "1" ] && [ "$RECONCILE" != "1" ]; then
  die "'$APP' is already declared in $SECRETS_FILE.
     Pass --reconcile to fill in anything missing without touching what is there."
fi

COMPOSE="$REPO_ROOT/$APP/docker-compose.prod.yml"
[ -n "$IMAGE" ]    || IMAGE="$(grep -oE '^[[:space:]]*image:[[:space:]]*\S+' "$COMPOSE" 2>/dev/null | head -n1 | awk '{print $2}' || true)"
[ -n "$UPSTREAM" ] || UPSTREAM="$(grep -oE '127\.0\.0\.1:[0-9]+' "$COMPOSE" 2>/dev/null | head -n1 || true)"
[ -n "$SERVER" ]   || SERVER="$(secrets_get '.infra.server')"
if [ -z "$DOMAIN" ] && [ "$EXISTS" = "0" ]; then
  die "'$APP' needs a --domain. It is the exact name Caddy asks Let's Encrypt for, so
     there is no sensible default to guess."
fi

PREFIX="$(manifest_env_prefix "$APP")"
[ -n "$PREFIX" ] || die "$APP/manifest.yaml has no env_prefix"

step "Declaring $APP in $SECRETS_FILE"

#: Only writes when the value is currently unset. That single rule is what makes
#: declare and reconcile the same operation, which is what stops them drifting apart.
set_if_empty() {  # set_if_empty PATH VALUE
  local path="$1" value="$2" current short
  [ -n "$value" ] || return 0
  current="$(yq -r "$path // \"\"" "$SECRETS_FILE")"
  [ "$current" = "null" ] && current=""
  [ -n "$current" ] && return 0
  short="${path#.apps.\""$APP"\".}"
  # One line either way, and it names the value. secrets_set has its own dry-run
  # print, but it reports the path without the value — and following "would set X"
  # with "set X = Y" reads as though the dry run had gone ahead and done it.
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would set $short = $value"
    return 0
  fi
  secrets_set "$path" "$value"
  echo "     set $short = $value"
}

set_if_empty "$APP_PATH.domain"     "$DOMAIN"
set_if_empty "$APP_PATH.upstream"   "$UPSTREAM"
set_if_empty "$APP_PATH.image"      "$IMAGE"
set_if_empty "$APP_PATH.server"     "$SERVER"
set_if_empty "$APP_PATH.managed_by" "docker"
# Written so a box running an older amber-infra — one whose install.sh still reads
# this field — resolves the same prefix the manifest names. install.sh refuses rather
# than choosing if the two ever disagree.
set_if_empty "$APP_PATH.env_prefix" "$PREFIX"

# --- adopt keys wearing the wrong prefix -------------------------------------
#
# This is what `repairBloom` was: a hand-written, one-app migration for a stanza
# declared with AGENT_MCP_KEYS by an app that reads BLOOM_MCP_KEYS. Generalised, it is
# "an orphan whose suffix matches a declared key is that key, misspelled" — and the
# value is worth keeping, because it is a working token somebody else may already
# hold.
if [ "$ADOPT" = "1" ]; then
  while IFS= read -r orphan; do
    [ -z "$orphan" ] && continue
    manifest_has_key "$APP" "$orphan" && continue
    suffix="${orphan#*_}"
    [ "$suffix" = "$orphan" ] && continue
    target="$(manifest_key_names "$APP" | grep -E "_${suffix}\$" | head -n1 || true)"
    [ -n "$target" ] || continue
    value="$(yq -r "$APP_PATH.env.\"$orphan\" // \"\"" "$SECRETS_FILE")"
    existing="$(yq -r "$APP_PATH.env.\"$target\" // \"\"" "$SECRETS_FILE")"
    case "$existing" in
      ''|null|*CHANGEME*)
        step "Adopting $orphan as $target"
        secrets_set "$APP_PATH.env.\"$target\"" "$value"
        dry || yq -i "del($APP_PATH.env.\"$orphan\")" "$SECRETS_FILE"
        ok "$target now holds the value $orphan had; $orphan removed" ;;
      *)
        warn "$target already has a value, so $orphan was left alone — delete it by hand once you are sure which is live" ;;
    esac
  done < <(yq -r "$APP_PATH.env // {} | keys | .[]" "$SECRETS_FILE" 2>/dev/null || true)
fi

# --- seed the env block from the manifest ------------------------------------
#
# Placeholders, not values. Nothing here invents a secret: `install.sh`'s own rule is
# that a value invented at a prompt is a value that is not in the backup, and the same
# applies to one invented by a declare step. fill-secrets.sh generates what the box
# can generate; the rest is a shopping list with a `help_url` beside each item.
step "Seeding ${PREFIX}_* keys the manifest declares"
SEEDED=""; NEEDS=""
while IFS= read -r key; do
  [ -z "$key" ] && continue
  kind="$(manifest_kind "$APP" "$key")"
  case "$kind" in
    # install.sh owns these; a placeholder in one reads as an outstanding task nobody
    # can do, so they are never written here.
    derived) continue ;;
    generated:openssl-hex-32) placeholder="CHANGEME-openssl-rand-hex-32" ;;
    generated:fernet)         placeholder="CHANGEME-fernet-generate-key" ;;
    generated:token)
      # A compound `name:tok,name:tok` list. The names come from the manifest because
      # they are the callers this app expects to hear from.
      placeholder=""
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        placeholder="${placeholder:+$placeholder,}$p:CHANGEME"
      done < <(manifest_peers "$APP" "$key")
      [ -n "$placeholder" ] || placeholder="Aperture:CHANGEME" ;;
    peer_token)               placeholder="CHANGEME-openssl-rand-hex-32" ;;
    config)                   placeholder="$(manifest_default "$APP" "$key")" ;;
    supplied)
      placeholder="CHANGEME"
      # Optional ones are listed too — the Spotify pair is a real thing you may want —
      # but marked, because a shopping list that does not say which items block the
      # install is a list you have to read twice.
      if manifest_is_required "$APP" "$key"; then
        NEEDS="$NEEDS
     $key — $(manifest_label "$APP" "$key")  $(manifest_help_url "$APP" "$key")"
      else
        NEEDS="$NEEDS
     $key — $(manifest_label "$APP" "$key")  (optional)  $(manifest_help_url "$APP" "$key")"
      fi ;;
    # A peer map needs real hostnames, which only exist once the peer is declared.
    peer_map)                 continue ;;
    *) warn "$key has kind '$kind', which this script does not know how to seed"; continue ;;
  esac
  [ -n "$placeholder" ] || continue
  before="$(yq -r "$APP_PATH.env.\"$key\" // \"\"" "$SECRETS_FILE")"
  set_if_empty "$APP_PATH.env.\"$key\"" "$placeholder"
  case "$before" in ''|null) SEEDED="$SEEDED $key" ;; esac
done < <(manifest_key_names "$APP")

[ -n "$SEEDED" ] && ok "seeded:$SEEDED"
# $DOMAIN, not a re-read: under --dry-run nothing was written, and reading it back
# would report `null` for the very value this run is about.
ok "$APP declared for ${DOMAIN:-$(yq -r "$APP_PATH.domain // \"\"" "$SECRETS_FILE")}"

if [ -n "$NEEDS" ]; then
  warn "these need a value only you have:$NEEDS"
fi
echo
echo "     Next: install/fill-secrets.sh --app $APP    (generates what the box can)"
echo "           install/install.sh --app $APP         (deploys it)"
