#!/usr/bin/env bash
#
# The pure string functions in install/connect-peer.sh, exercised.
#
#   bash tests/list-helpers.sh
#
# Why this file exists at all, when nothing else in this repo has one. Every other
# script here is judged by shellcheck and by `--dry-run` against a scratch secrets
# file, which is the right shape for code whose job is to call yq and docker. The
# list helpers are not that: they are parsers, they are the only place a bearer token
# is taken apart and put back together, and getting one wrong is silent. A merge that
# drops an entry does not fail — it revokes somebody's credential and reports success.
#
# It caught one on the first run, and it is exactly the trap deploy/status.sh's
# `key_list_json` documents in a comment: `tr ',' '\n'` leaves the FINAL entry
# unterminated, so a bare `while read` discards it. Every one of these six functions
# had it. The visible effect would have been `connect-peer.sh --from amber --to bloom`
# silently deleting the last key in Bloom's bearer list — most often Aperture's, since
# it is declared second — while printing " ok".
#
# No yq, no docker, no network, no secrets file. Stubs stand in for the three library
# calls the helper block happens to close over, so this runs anywhere bash does.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/install/connect-peer.sh"
[ -f "$SCRIPT" ] || { echo "error: no $SCRIPT" >&2; exit 1; }

# The helper block only, sliced out by its own section banners. Sourcing the whole
# script would run it — it parses arguments and calls secrets_check at the top level.
# Slicing means the functions under test are the ones actually shipped, rather than a
# copy here that drifts the first time one is edited.
BLOCK="$(mktemp)"
trap 'rm -f "$BLOCK"' EXIT
sed -n '/^# ==== list helpers/,/^# ==== what the manifests say/p' "$SCRIPT" > "$BLOCK"
grep -q '^keylist_set()' "$BLOCK" || {
  echo "error: could not slice the helper block out of connect-peer.sh." >&2
  echo "       Did a section banner get renamed? This test greps for the two" >&2
  echo "       '# ==== …' lines that bound it." >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }
secrets_get() { echo ""; }
container_health() { echo missing; }
sync_store_up() { return 1; }
# shellcheck source=/dev/null
. "$BLOCK"

FAILS=0
eq() {  # eq LABEL GOT WANT
  if [ "$2" = "$3" ]; then
    printf '  ok  %s\n' "$1"
  else
    printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"
    FAILS=$((FAILS + 1))
  fi
}

echo "== keylist_get"
eq "finds a named entry"        "$(keylist_get 'amber:abc,Aperture:def' amber)" "abc"
eq "absent name is empty"       "$(keylist_get 'Aperture:def' amber)" ""
# parse_keys treats a colon-less entry as a bare token labelled by its own
# fingerprint, so it has no name and must never match one.
eq "a bare token has no name"   "$(keylist_get 'bareToken' amber)" ""
eq "tolerates whitespace"       "$(keylist_get 'amber: abc , x:y' amber)" "abc"
# `partition(":")` splits on the FIRST colon, so the token half keeps the rest.
eq "token may contain colons"   "$(keylist_get 'amber:a:b:c' amber)" "a:b:c"
# The regression: the final entry is the one `tr` leaves unterminated.
eq "reads the LAST entry"       "$(keylist_get 'x:y,amber:abc' amber)" "abc"
eq "reads a lone entry"         "$(keylist_get 'amber:abc' amber)" "abc"

echo "== keylist_set"
eq "replaces in place"          "$(keylist_set 'amber:old,Aperture:def' amber new)" "amber:new,Aperture:def"
eq "appends when new"           "$(keylist_set 'Aperture:def' amber new)" "Aperture:def,amber:new"
eq "appends to an empty list"   "$(keylist_set '' amber new)" "amber:new"
# The property the whole file is for: nobody else's entry moves.
eq "preserves a bare token"     "$(keylist_set 'bare,Aperture:def' amber new)" "bare,Aperture:def,amber:new"
eq "preserves the last entry"   "$(keylist_set 'amber:old,Aperture:def' amber new)" "amber:new,Aperture:def"
eq "drops a trailing comma"     "$(keylist_set 'Aperture:def,' amber new)" "Aperture:def,amber:new"

echo "== keylist_del"
eq "removes the named entry"    "$(keylist_del 'amber:abc,Aperture:def' amber)" "Aperture:def"
eq "removing the last empties"  "$(keylist_del 'amber:abc' amber)" ""
eq "absent name is a no-op"     "$(keylist_del 'Aperture:def' amber)" "Aperture:def"
eq "keeps a trailing entry"     "$(keylist_del 'amber:abc,x:y' amber)" "x:y"

echo "== peermap"
eq "get"                        "$(peermap_get 'bloom=https://b,f=https://f' bloom)" "https://b"
eq "get: last entry"            "$(peermap_get 'f=https://f,bloom=https://b' bloom)" "https://b"
eq "get: absent"                "$(peermap_get 'f=https://f' bloom)" ""
eq "set: replaces"              "$(peermap_set 'bloom=https://old,f=https://f' bloom https://new)" "bloom=https://new,f=https://f"
eq "set: appends"               "$(peermap_set 'f=https://f' bloom https://b)" "f=https://f,bloom=https://b"
eq "set: into an empty map"     "$(peermap_set '' bloom https://b)" "bloom=https://b"
eq "del"                        "$(peermap_del 'bloom=https://b,f=https://f' bloom)" "f=https://f"
eq "del: last one empties"      "$(peermap_del 'bloom=https://b' bloom)" ""
eq "names"                      "$(peermap_names 'bloom=https://b,f=https://f' | tr '\n' ' ')" "bloom f "
eq "names: empty map"           "$(peermap_names '')" ""

echo "== fp8"
eq "is stable"                  "$(fp8 abc123)" "$(fp8 abc123)"
eq "empty in, empty out"        "$(fp8 '')" ""
eq "distinguishes"              "$(if [ "$(fp8 a)" != "$(fp8 b)" ]; then echo differs; fi)" "differs"
eq "does not leak the value"    "$(if [ "$(fp8 supersecret)" = "supersecret" ]; then echo leak; else echo safe; fi)" "safe"

# The URL rule, spelled here the way connect-peer.sh spells it. agent_runtime's
# MCPClient._endpoint only guards a trailing `/mcp` with no slash, so `/mcp/` would
# survive and become `/mcp//mcp/`. Both forms have to be stripped at the door.
echo "== base url"
strip() { local b="$1"; b="${b%/}"; b="${b%/mcp}"; b="${b%/}"; printf '%s' "$b"; }
eq "plain base url"             "$(strip https://bloom.x)" "https://bloom.x"
eq "trailing slash"             "$(strip https://bloom.x/)" "https://bloom.x"
eq "an endpoint pasted in"      "$(strip https://bloom.x/mcp)" "https://bloom.x"
eq "an endpoint with a slash"   "$(strip https://bloom.x/mcp/)" "https://bloom.x"

echo
if [ "$FAILS" -eq 0 ]; then
  echo " ok  all assertions passed"
else
  echo "error: $FAILS assertion(s) failed" >&2
  exit 1
fi
