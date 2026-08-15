#!/usr/bin/env bash
#
# Reading /etc/amber-infra/secrets.yaml.
#
# A thin wrapper over `yq` (v4) and nothing more. There is deliberately no fallback
# parser: YAML in shell is where this repo would rot, and yq is one apt package.
#
# Every read goes through secrets_get or secrets_require so that "the key is
# missing" and "the key is still CHANGEME" produce the same clear failure, naming
# the yq path, rather than an empty string that propagates into a rendered .env and
# surfaces three steps later as an unauthorized peer call.

# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

[ -n "${_AMBER_INFRA_SECRETS:-}" ] && return 0
_AMBER_INFRA_SECRETS=1

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SECRETS_FILE="${SECRETS_FILE:-/etc/amber-infra/secrets.yaml}"

secrets_check() {
  [ -f "$SECRETS_FILE" ] || die "no secrets file at $SECRETS_FILE — install.sh step 1 copies the example there"
  have yq || die "yq (v4) is required to read $SECRETS_FILE"
}

secrets_get() {  # secrets_get '.apps.amber.domain' [default]
  local path="$1" default="${2:-}" value
  secrets_check
  value="$(yq -r "$path // \"\"" "$SECRETS_FILE" 2>/dev/null || true)"
  [ "$value" = "null" ] && value=""
  echo "${value:-$default}"
}

secrets_require() {  # secrets_require '.infra.acme_email'
  local path="$1" value
  value="$(secrets_get "$path")"
  case "$value" in
    '')          die "$SECRETS_FILE: $path is not set" ;;
    *CHANGEME*)  die "$SECRETS_FILE: $path is still a CHANGEME placeholder" ;;
  esac
  echo "$value"
}

secrets_set() {  # secrets_set '.sync_store.keys[0].token' VALUE — write back in place
  local path="$1" value="$2"
  secrets_check
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would set $path in $SECRETS_FILE"
    return 0
  fi
  V="$value" yq -i "$path = strenv(V)" "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
}

secrets_sync_store_keys() {
  # Render sync_store.keys[] into the SYNC_STORE_KEYS wire format:
  #   "amber:tok,Aperture:tok,spawner:tok"
  # The name half is what the store logs when that caller registers; the token
  # half never appears in a log line. See sync-store/app/auth.py.
  secrets_check
  yq -r '.sync_store.keys[] | .name + ":" + .token' "$SECRETS_FILE" | paste -sd, -
}

secrets_render_env() {  # secrets_render_env APP DEST — write apps.<APP>.env into DEST
  local app="$1" dest="$2" key value placeholders=""
  secrets_check
  step "Rendering $dest from $SECRETS_FILE (.apps.$app.env)"
  run install -m 600 -o root -g root /dev/null "$dest"
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    value="$(secrets_get ".apps.\"$app\".env.\"$key\"")"
    # This copy is verbatim and always has been, which is how the word CHANGEME ends
    # up mounted as a live bearer token on a public HTTPS endpoint. install.sh's
    # manifest_check refuses that before anything is written, but only for an app that
    # has a manifest and only for keys it marks required — so say it here too, for
    # everything else. Named rather than counted: "3 placeholders" sends you looking.
    case "$value" in *CHANGEME*) placeholders="$placeholders $key" ;; esac
    env_set "$dest" "$key" "$value"
  done < <(yq -r ".apps.\"$app\".env // {} | keys | .[]" "$SECRETS_FILE")
  env_protect "$dest"
  ok "wrote $dest"
  [ -z "$placeholders" ] || warn "$dest still holds placeholder values for:$placeholders
     Whatever reads them will receive the literal string CHANGEME."
}
