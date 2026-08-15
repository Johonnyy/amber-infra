#!/usr/bin/env bash
#
# .env file manipulation.
#
# env_set is copied VERBATIM from amber_v2/deploy/update.sh:128-140, and that is
# load-bearing, not laziness. Both this repo and Amber's own updater edit
# /etc/amber-infra/amber/amber.env; two different writers with two different
# escaping rules is precisely how a file grows duplicate keys, and a duplicate key
# in a systemd EnvironmentFile or a docker env_file resolves to whichever one the
# parser saw last.
#
# The awk+ENVIRON form treats the value as a literal — any character is safe, with
# no sed-delimiter or backslash-escape pitfalls. `sed -i "s|^$k=.*|$k=$v|"` looks
# equivalent and breaks the first time a token contains a pipe.
#
# The safety property that makes the two writers coexist: update.sh only ADDS keys
# that are missing and never overwrites an existing value, so a value written once
# by install.sh survives every subsequent update.

# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

[ -n "${_AMBER_INFRA_ENV:-}" ] && return 0
_AMBER_INFRA_ENV=1

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

env_has() { grep -qE "^$2=" "$1"; }                            # env_has FILE KEY
env_get() { grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-; }   # env_get FILE KEY

env_set() {  # env_set FILE KEY VALUE — replace in place or append, never duplicate
  local file="$1" key="$2" val="$3" tmp
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would set $key in $file"
    return 0
  fi
  [ -f "$file" ] || { install -m 600 /dev/null "$file"; }
  if env_has "$file" "$key"; then
    tmp="$(mktemp)"
    K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
      {if (index($0, k"=")==1) print k"="v; else print}' "$file" > "$tmp"
    cat "$tmp" > "$file"; rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

env_reconcile() {  # env_reconcile FILE EXAMPLE [PREFIX]
  # Add every key the example defines and the live file lacks, carrying the
  # example's default. Never touches an existing value.
  #
  # This is the container-era replacement for update.sh step 4a. Under systemd the
  # example sat next to the code in the checkout; in a container it is baked into
  # the image at /srv/.env.example and read out with `docker run --entrypoint cat`
  # (see env_example_from_image). The logic is otherwise identical, because it was
  # already right.
  local file="$1" example="$2" prefix="${3:-}" added=() key line
  [ -f "$example" ] || die "missing $example"
  if [ ! -f "$file" ]; then
    warn "$file missing — creating it from $example"
    run install -m 600 "$example" "$file"
  fi
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key=${line%%=*}
    [ "$key" = "$line" ] && continue            # line had no '='
    if [ -n "$prefix" ]; then
      case "$key" in "$prefix"*) ;; *) continue ;; esac
    fi
    if ! env_has "$file" "$key"; then
      dry || printf '%s\n' "$line" >> "$file"
      added+=("$key")
    fi
  done < "$example"
  if [ "${#added[@]}" -gt 0 ]; then
    ok "added ${#added[@]} new key(s) with defaults: ${added[*]}"
  else
    ok "no new keys in $(basename "$example")"
  fi
}

env_example_from_image() {  # env_example_from_image IMAGE DEST -> 0 when it got one
  # Pull /srv/.env.example out of an image so env_reconcile has something to diff
  # against. Amber's Dockerfile bakes it in for exactly this.
  #
  # **Returns non-zero rather than dying**, and that distinction is the whole point of
  # the function. Its one caller (deploy/update-app.sh) is written to warn and skip
  # reconciliation when there is no example — which was dead code while this `die`d,
  # so an image without one could not be updated *at all*. The sync-store was the
  # first: four pure-Python deps, no baked example, and every update stopped here with
  # a `cat` error and no explanation of why that was fatal.
  #
  # It should not be fatal. Reconciliation is a convenience — new keys arrive carrying
  # their defaults — not a correctness gate. The check that must fail loudly is
  # `env_require` immediately after, which refuses to restart into a configuration
  # missing a value a human has to supply, and it is untouched by this.
  local image="$1" dest="$2"
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would extract .env.example from $image"
    return 0
  fi
  if ! docker run --rm --entrypoint cat "$image" /srv/.env.example > "$dest" 2>/dev/null; then
    : > "$dest"   # a failed redirect can leave a partial file; never diff against one
    return 1
  fi
}

env_require() {  # env_require FILE KEY... — die on any key still unset or CHANGEME
  local file="$1"; shift
  local key value missing=()
  for key in "$@"; do
    value="$(env_get "$file" "$key" || true)"
    case "$value" in
      ''|*CHANGEME*|*'...'*) missing+=("$key") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "$file is missing required value(s): ${missing[*]}
     Fill them in /etc/amber-infra/secrets.yaml and re-run, rather than editing
     the generated file — the next install would overwrite a hand edit."
  fi
}

env_protect() {  # env_protect FILE — an env file holds every secret the app has
  run chmod 600 "$1"
  run chown root:root "$1"
}
