#!/usr/bin/env bash
#
# Wire one app to call another's MCP server.
#
#   connect-peer.sh --from amber --to bloom
#   connect-peer.sh --from amber --to bloom --dry-run
#   connect-peer.sh --from amber --to bloom --disconnect
#
# The failure this exists to end. Bloom registered perfectly, appeared in
# GET /servers, mounted its MCP server and answered 401 to an unauthenticated
# probe — every green light a status screen can show — and Amber had no tool for
# it, because AMBER_MCP_PEERS was empty and her broker is built from that alone.
# There is no error anywhere in that state. The peer is simply not offered, and the
# only symptom is a model that does not mention a capability you believe it has.
#
# Wiring it by hand is four facts in the right shape, and three of them are easy to
# get wrong in a way that fails as a plain 401 or a 404:
#
#   * AMBER_MCP_PEERS takes a BASE url. The client appends /mcp/ itself, so pasting
#     the endpoint yields /mcp/mcp/ and a 404 that reads as "Bloom is down".
#   * AMBER_MCP_PEER_TOKEN is the token HALF of Bloom's BLOOM_MCP_KEYS. If that is
#     `amber:abc123`, the value is `abc123` — not `amber:abc123`.
#   * The name half must be the CALLER's name, because that is what the far end logs
#     the call as (see sync-store/app/auth.py's parse_keys).
#   * Both apps have to agree, and the two values live in two stanzas of one file.
#
# So this reads the pairing out of the manifests rather than asking anyone to
# remember it. `amber/manifest.yaml` declares AMBER_MCP_PEER_TOKEN as
# `kind: peer_token, peer_of: bloom, peer_key: BLOOM_MCP_KEYS`, and
# `bloom/manifest.yaml` declares BLOOM_MCP_KEYS as `generated:token, peers: [amber]`.
# Those two facts are the whole operation; every value below is derived from them.
# `install/lib/manifest.sh` has had the accessors for this since the manifests
# landed — this is the first caller.
#
# THREE PROPERTIES, all of which the repo already holds every other script to:
#
#   * **Idempotent.** Re-running changes nothing and says so. An existing token is
#     reused, never regenerated: it may already be rendered into a running
#     container's env, and minting a fresh one to "fix" a link that works would
#     break it until both sides restarted.
#   * **Additive.** The peer map and the key list are both comma-separated lists
#     with other people's entries in them. Every write here merges — replacing the
#     one entry named, leaving the rest — because clobbering Aperture's admin key to
#     add Amber's peer key is a way to take down a working thing while fixing a
#     broken one.
#   * **No token is ever printed.** Not to stdout, not to a log, not into argv.
#     Values move between shell locals and yq via `strenv`; what is reported is an
#     eight-hex fingerprint, the same label sync-store/app/auth.py stamps on a bare
#     token, so two ends can be COMPARED on screen without either being disclosed.
#
# It writes secrets.yaml, which is the *source*. The running container reads a
# rendered .env, so nothing takes effect until the caller is installed/reconciled —
# `install.sh --app <caller>` is what renders and restarts. `declare.sh --reconcile`
# does NOT: it is config-only, by its own docstring. This script says so at the end
# rather than leaving you to discover that the change did not land.
#
# It also PUTs the token to the registry, so the SAME operation satisfies both paths
# to a peer: the static env map (which is what an already-deployed agent reads) and
# the sync store's discovered layer (which is what `agent_mcp.PeerRegistry.refresh`
# hands out, and what removes the one-token ceiling described under LIMITS below).
# Best effort, and last: a registry that is down must not fail the half that works.
#
# LIMITS. `agent_mcp.load_static_peers(spec, token)` applies ONE token to EVERY peer
# in the map. So the static path is exact for one peer and cannot express two peers
# with different credentials — which is the normal case the moment a third app
# exists. This script detects that and says so rather than writing a map that is
# quietly wrong for every peer but the last. The fix is discovery, which is why the
# registry PUT is not optional decoration.
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
# shellcheck source=lib/sync_store.sh
. "$REPO_ROOT/install/lib/sync_store.sh"

FROM=""; TO=""; DISCONNECT=0; NO_REGISTRY=0

usage() {
  cat <<'USAGE'
usage: connect-peer.sh --from CALLER --to CALLEE [options]

  --from NAME     the app that will make the calls (needs a peer_map key)
  --to NAME       the app it will call (needs a generated:token key naming it)
  --disconnect    undo it: drop the map entry and revoke the caller's key
  --no-registry   skip the sync-store token PUT (config file only)
  --secrets FILE  operate on FILE instead of /etc/amber-infra/secrets.yaml
  --dry-run       print what would change

Both apps must have a manifest.yaml in this checkout: the pairing is read from
there, not guessed. Nothing takes effect until the CALLER is reconciled —
install.sh --app CALLER renders its .env and restarts it.
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)        FROM="$2"; shift 2 ;;
    --to)          TO="$2"; shift 2 ;;
    --disconnect)  DISCONNECT=1; shift ;;
    --no-registry) NO_REGISTRY=1; shift ;;
    --secrets)     SECRETS_FILE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

# One guard per line, the way declare.sh spells it. `A && B || usage` reads as
# if-then-else and is not one: C runs whenever the AND-list is false, which happens
# to be right here and stops being right the moment anyone adds a fourth clause.
[ -n "$FROM" ] || usage
[ -n "$TO" ] || usage
[ "$FROM" != "$TO" ] || die "an app cannot be its own peer"
secrets_check
require_cmd yq

# ==== list helpers ===========================================================
#
# Both formats this script edits are comma-separated lists that belong to more than
# one relationship, so every operation is a merge over entries rather than a write
# of a whole value. They are kept as plain string functions — no arrays, no temp
# files — because a token passes through them and a temp file holding one is a
# thing to explain to whoever finds it.
#
#   key list:  "amber:tok,Aperture:tok"    (agent_mcp.parse_keys)
#   peer map:  "bloom=https://bloom.x,fin=https://fin.x"  (agent_mcp.load_static_peers)

#: Eight hex of a sha256 — enough to COMPARE two values on screen, no step at all
#: toward reconstructing either. Mirrors deploy/status.sh's fingerprint().
fp8() {
  [ -n "${1:-}" ] || return 0
  if   have sha256sum; then printf '%s' "$1" | sha256sum     | cut -c1-8
  elif have shasum;    then printf '%s' "$1" | shasum -a 256 | cut -c1-8
  elif have openssl;   then printf '%s' "$1" | openssl dgst -sha256 -r | cut -c1-8
  else echo "????????"
  fi
}

#: Whether the registry can be talked to at all, without dying if it cannot.
#:
#: `sync_store_up` falls through to `sync_store_base_url`, which calls
#: `secrets_require '.sync_store.url'` — and `secrets_require` DIES on an unset key.
#: That is right for install.sh, where a box with no registry URL is a misconfigured
#: install; it is wrong here, where the registry half is explicitly best-effort and
#: an aborted run would leave the env map half written. Checking the URL first turns
#: the fatal path into a false.
#: Spelled with an `if` rather than `[ … ] && return 0`, even though sync_store_up
#: uses the latter: that form only survives `set -e` because sync_store_up happens to
#: be called from a condition, which disables it for the whole function body. This one
#: should not depend on how its callers are written.
registry_ready() {
  if [ "$(container_health sync-store 2>/dev/null || true)" = "healthy" ]; then return 0; fi
  [ -n "$(secrets_get '.sync_store.url')" ] || return 1
  sync_store_up
}

#: The token an entry named NAME carries, or "" — parsing exactly as parse_keys does,
#: including its rule that an entry with NO colon is a bare token whose caller label
#: is its own fingerprint (and so can never be named, and is left alone here).
keylist_get() {  # keylist_get LIST NAME
  local list="$1" want="$2" entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      "$want":*) printf '%s' "${entry#*:}"; return 0 ;;
    esac
  done < <(printf '%s' "$list" | tr ',' '\n')
  return 0
}

#: LIST with NAME's entry set to TOKEN (replaced in place, or appended), every other
#: entry preserved byte for byte. Appending rather than rebuilding matters: a bare
#: token with no name is legitimate and unnameable, and a rebuild that only knew how
#: to emit `name:token` would silently drop it.
keylist_set() {  # keylist_set LIST NAME TOKEN
  local list="$1" want="$2" token="$3" entry out="" found=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      "$want":*) entry="$want:$token"; found=1 ;;
    esac
    out="${out:+$out,}$entry"
  done < <(printf '%s' "$list" | tr ',' '\n')
  [ "$found" = "1" ] || out="${out:+$out,}$want:$token"
  printf '%s' "$out"
}

keylist_del() {  # keylist_del LIST NAME
  local list="$1" want="$2" entry out=""
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in "$want":*) continue ;; esac
    out="${out:+$out,}$entry"
  done < <(printf '%s' "$list" | tr ',' '\n')
  printf '%s' "$out"
}

peermap_get() {  # peermap_get MAP NAME -> the base url, or ""
  local map="$1" want="$2" entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      "$want"=*) printf '%s' "${entry#*=}"; return 0 ;;
    esac
  done < <(printf '%s' "$map" | tr ',' '\n')
  return 0
}

peermap_set() {  # peermap_set MAP NAME URL
  local map="$1" want="$2" url="$3" entry out="" found=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      "$want"=*) entry="$want=$url"; found=1 ;;
    esac
    out="${out:+$out,}$entry"
  done < <(printf '%s' "$map" | tr ',' '\n')
  [ "$found" = "1" ] || out="${out:+$out,}$want=$url"
  printf '%s' "$out"
}

peermap_del() {  # peermap_del MAP NAME
  local map="$1" want="$2" entry out=""
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in "$want"=*) continue ;; esac
    out="${out:+$out,}$entry"
  done < <(printf '%s' "$map" | tr ',' '\n')
  printf '%s' "$out"
}

peermap_names() {  # peermap_names MAP -> one name per line
  printf '%s' "$1" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' | cut -d= -f1 || true
}

#: Whether APP's KEY lists CALLER under `peers:`.
#:
#: awk rather than `grep -qxF`, and the reason is copied verbatim from
#: install/lib/manifest.sh: `grep -q` exits at the first match, the producer dies on
#: the closed pipe, and under `set -o pipefail` the pipeline reports failure — so the
#: caller concludes the peer was NOT listed, which is the exact opposite of what
#: happened. awk consumes all of its input, so there is no closed pipe and no
#: spurious failure. (`manifest_peers` currently ends in `|| true`, which happens to
#: mask this; relying on an implementation detail of another file for correctness
#: here is not a thing to leave in place.)
peers_include() {  # peers_include APP KEY CALLER
  manifest_peers "$1" "$2" | awk -v c="$3" '$0 == c { found = 1 } END { exit !found }'
}

#: The KEY on CALLEE whose `peers:` names CALLER, or "" — the accepting half of a
#: link. Read from the callee's own manifest, because that is the app that decides
#: what it reads; the caller's `peer_key` hint is per-pair and hardcodes one app name.
accepting_key_of() {  # accepting_key_of CALLEE CALLER
  local callee="$1" caller="$2" key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if peers_include "$callee" "$key" "$caller"; then printf '%s' "$key"; return 0; fi
  done < <(manifest_names_of_kind "$callee" '^generated:token$')
  return 0
}

# ==== what the manifests say =================================================

manifest_have "$FROM" || die "no $FROM/manifest.yaml in this checkout.
     The pairing is read from the manifests rather than guessed, so an app without
     one cannot be wired here. Add $FROM/manifest.yaml, or set the two keys by hand."
manifest_have "$TO" || die "no $TO/manifest.yaml in this checkout."

PEER_MAP_KEY="$(manifest_names_of_kind "$FROM" '^peer_map$' | head -n1)"
PEER_TOKEN_KEY="$(manifest_names_of_kind "$FROM" '^peer_token$' | head -n1)"

[ -n "$PEER_MAP_KEY" ] || die "$FROM/manifest.yaml declares no 'peer_map' key.
     That key is the list of peers $FROM may call. Without it there is nowhere to
     write this link, and $FROM has no way to reach another app's MCP server."
[ -n "$PEER_TOKEN_KEY" ] || die "$FROM/manifest.yaml declares no 'peer_token' key."

#: The callee's key whose `peers:` list names the caller — the accepting half.
#:
#: Resolved from the CALLEE's manifest rather than from the caller's `peer_key`
#: hint, because the hint is per-pair and hardcodes one app name (`peer_of: bloom`),
#: which stops being true the moment there is a third app. The hint is still read
#: below, as a cross-check: if the two disagree, one of the manifests is stale, and
#: that is worth a warning rather than a silent choice between them.
accepting_key="$(accepting_key_of "$TO" "$FROM")"

declared_key="$(manifest_peer_key "$FROM" "$PEER_TOKEN_KEY")"
declared_of="$(manifest_peer_of "$FROM" "$PEER_TOKEN_KEY")"

if [ -z "$accepting_key" ]; then
  # The caller's own hint is the fallback, but only when it is about THIS callee —
  # using `peer_key` while ignoring `peer_of` would happily write Bloom's key name
  # into a third app's stanza.
  if [ -n "$declared_key" ] && [ "$declared_of" = "$TO" ]; then
    accepting_key="$declared_key"
    warn "$TO/manifest.yaml does not list '$FROM' under any generated:token key.
     Falling back to $FROM/manifest.yaml's peer_key hint ($declared_key).
     Add 'peers: [$FROM]' to $accepting_key in $TO/manifest.yaml to make this explicit."
  else
    die "$TO/manifest.yaml has no generated:token key listing '$FROM' as a peer.
     That list is what says '$FROM is allowed to call me, under this name'. Add
     'peers: [$FROM]' to the key $TO accepts bearers on, then re-run this."
  fi
elif [ -n "$declared_key" ] && [ "$declared_of" = "$TO" ] && [ "$declared_key" != "$accepting_key" ]; then
  warn "$FROM/manifest.yaml says the token for '$TO' lives in $declared_key, but
     $TO/manifest.yaml says $FROM presents its bearer on $accepting_key. Using
     $accepting_key ($TO's own account of what it reads); fix the stale one."
fi

CALLER_ENV=".apps.\"$FROM\".env"
CALLEE_ENV=".apps.\"$TO\".env"

[ "$(secrets_get ".apps.\"$FROM\"")" != "" ] || die "'$FROM' is not declared in $SECRETS_FILE.
     Declare it first: install/declare.sh --app $FROM"
[ "$(secrets_get ".apps.\"$TO\"")" != "" ] || die "'$TO' is not declared in $SECRETS_FILE.
     Declare it first: install/declare.sh --app $TO"

step "Peering $FROM -> $TO"
echo "     caller writes:  $PEER_MAP_KEY, $PEER_TOKEN_KEY"
echo "     callee accepts: $accepting_key"

CUR_MAP="$(secrets_get "$CALLER_ENV.\"$PEER_MAP_KEY\"")"
CUR_KEYS="$(secrets_get "$CALLEE_ENV.\"$accepting_key\"")"

# ==== disconnect =============================================================
#
# Symmetric with connect, and it revokes rather than merely unlinking. Leaving the
# caller's entry in the callee's bearer list would leave a valid credential that
# nothing accounts for — the same objection renameApp raises about a name left
# behind in six places, and the reason uninstall.sh drops an app's sync-store key.

if [ "$DISCONNECT" = "1" ]; then
  changed=0

  if [ -n "$(peermap_get "$CUR_MAP" "$TO")" ]; then
    secrets_set "$CALLER_ENV.\"$PEER_MAP_KEY\"" "$(peermap_del "$CUR_MAP" "$TO")"
    ok "removed '$TO' from $PEER_MAP_KEY"
    changed=1
  else
    ok "$PEER_MAP_KEY does not mention '$TO' — nothing to remove"
  fi

  if [ -n "$(keylist_get "$CUR_KEYS" "$FROM")" ]; then
    remaining="$(keylist_del "$CUR_KEYS" "$FROM")"
    if [ -z "$remaining" ]; then
      # agent-mcp-py fails closed: an app with an EMPTY key list does not mount its
      # MCP server at all. Revoking the last bearer would therefore take the callee
      # off the network entirely — a much larger act than unlinking one caller, and
      # not one to perform as a side effect. Left in place, and said out loud.
      warn "'$FROM' is the only bearer in $TO's $accepting_key, and an empty list
     makes agent-mcp-py fail closed — $TO would stop mounting its MCP server and
     drop out of the registry. Leaving the key in place; remove it by hand if
     taking $TO off the network is what you meant."
    else
      secrets_set "$CALLEE_ENV.\"$accepting_key\"" "$remaining"
      ok "revoked $FROM's bearer from $TO's $accepting_key"
      changed=1
    fi
  else
    ok "$TO's $accepting_key has no entry for '$FROM' — nothing to revoke"
  fi

  # The peer token is shared across every peer in the map (see LIMITS), so it is
  # only safe to clear once the map is empty. Clearing it while another peer
  # remained would break that peer to tidy up after this one.
  left="$(peermap_del "$CUR_MAP" "$TO")"
  if [ -z "$left" ] && [ -n "$(secrets_get "$CALLER_ENV.\"$PEER_TOKEN_KEY\"")" ]; then
    secrets_set "$CALLER_ENV.\"$PEER_TOKEN_KEY\"" ""
    ok "cleared $PEER_TOKEN_KEY — $FROM has no peers left"
  fi

  if [ "$NO_REGISTRY" != "1" ]; then
    admin="$(sync_store_admin_token)"
    if [ -n "$admin" ] && registry_ready; then
      if run curl -fsS -X PUT "$(sync_store_base_url)/servers/$TO/token" \
          -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
          --data '{"token": ""}' >/dev/null 2>&1; then
        ok "cleared '$TO's peer credential in the registry"
      else
        warn "could not clear '$TO's token in the registry (it may not be registered)"
      fi
    fi
  fi

  # An `if`, not `[ … ] && echo && warn`: that form is an AND-list whose overall
  # status is 1 when nothing changed, and `set -e` exits on it — so a disconnect that
  # correctly found nothing to do would report failure.
  if [ "$changed" = "1" ]; then
    echo
    warn "reconcile $FROM to render the change:
     install/install.sh --app $FROM"
  fi
  exit 0
fi

# ==== the token ==============================================================
#
# Reused when it exists, minted when it does not. Never regenerated for a link that
# already works: the value may be rendered into a running container's env on both
# sides, and replacing it to "repair" a healthy pairing breaks it until each end is
# restarted — a self-inflicted outage in the middle of a convenience.

TOKEN="$(keylist_get "$CUR_KEYS" "$FROM")"
minted=0
case "$TOKEN" in
  *CHANGEME*)
    warn "$TO's $accepting_key holds a CHANGEME for '$FROM' — replacing it with a real token"
    TOKEN=""
    ;;
esac
if [ -z "$TOKEN" ]; then
  TOKEN="$(gen_token)"
  minted=1
fi

# The base URL, from the registry when it knows and the declared domain otherwise.
#
# The registry first because it is what every OTHER agent resolves through, so
# taking it from anywhere else can wire this one caller to an address the fleet
# disagrees about. The domain is the fallback that works before the callee has ever
# registered — which is exactly the state someone is in when first wiring an app.
BASE=""
ADMIN="$(sync_store_admin_token)"
if [ -n "$ADMIN" ] && registry_ready; then
  BASE="$(curl -fsS --max-time 6 -H "Authorization: Bearer $ADMIN" \
    "$(sync_store_base_url)/servers/$TO" 2>/dev/null \
    | yq -p=json -r '.base_url // ""' 2>/dev/null || true)"
  if [ "$BASE" = "null" ]; then BASE=""; fi
fi
if [ -z "$BASE" ]; then
  domain="$(secrets_get ".apps.\"$TO\".domain")"
  [ -n "$domain" ] || die "'$TO' is not in the registry and has no domain in $SECRETS_FILE,
     so there is no address to call it at. Set apps.$TO.domain, or install it so it
     registers itself."
  BASE="https://$domain"
  warn "'$TO' is not in the registry yet — using its declared domain, $BASE"
fi

# A BASE url, never an endpoint. agent_runtime's MCPClient appends /mcp/ itself, and
# its _endpoint() only guards against a trailing /mcp with no slash — so a stored
# `https://bloom.x/mcp/` becomes `https://bloom.x/mcp//mcp/`. Both forms are stripped
# here, at the one place a human-supplied URL enters the system.
BASE="${BASE%/}"
BASE="${BASE%/mcp}"
BASE="${BASE%/}"

# ==== write ==================================================================

NEW_MAP="$(peermap_set "$CUR_MAP" "$TO" "$BASE")"
CUR_TOKEN="$(secrets_get "$CALLER_ENV.\"$PEER_TOKEN_KEY\"")"

if [ "$NEW_MAP" = "$CUR_MAP" ] && [ "$CUR_TOKEN" = "$TOKEN" ] && [ "$minted" = "0" ]; then
  ok "$FROM -> $TO is already wired ($TO at $BASE, bearer sha256:$(fp8 "$TOKEN"))"
else
  if [ "$minted" = "1" ]; then
    secrets_set "$CALLEE_ENV.\"$accepting_key\"" "$(keylist_set "$CUR_KEYS" "$FROM" "$TOKEN")"
    ok "minted a bearer for '$FROM' in $TO's $accepting_key (sha256:$(fp8 "$TOKEN"))"
  else
    ok "reusing the bearer already in $TO's $accepting_key (sha256:$(fp8 "$TOKEN"))"
  fi

  secrets_set "$CALLER_ENV.\"$PEER_MAP_KEY\"" "$NEW_MAP"
  ok "$PEER_MAP_KEY: $TO = $BASE"

  secrets_set "$CALLER_ENV.\"$PEER_TOKEN_KEY\"" "$TOKEN"
  ok "$PEER_TOKEN_KEY set (sha256:$(fp8 "$TOKEN"))"
fi

# The one-token ceiling, checked rather than assumed.
#
# load_static_peers applies a SINGLE token to every peer in the map, so a second peer
# whose bearer differs is not partially configured — it is a map in which exactly one
# entry can work and the others 401, with the env file looking entirely correct. This
# is the point at which that becomes true, so this is where it is said.
others="$(peermap_names "$NEW_MAP" | grep -vxF "$TO" || true)"
if [ -n "$others" ]; then
  clash=""
  while IFS= read -r other; do
    [ -n "$other" ] || continue
    manifest_have "$other" || continue
    other_key="$(accepting_key_of "$other" "$FROM")"
    [ -n "$other_key" ] || continue
    other_token="$(keylist_get "$(secrets_get ".apps.\"$other\".env.\"$other_key\"")" "$FROM")"
    [ -n "$other_token" ] || continue
    [ "$other_token" = "$TOKEN" ] || clash="${clash:+$clash, }$other"
  done <<<"$others"

  if [ -n "$clash" ]; then
    warn "$FROM now lists more than one peer, and $PEER_TOKEN_KEY holds ONE token for
     all of them. These expect a different bearer and will answer 401: $clash

     agent_mcp.load_static_peers cannot express per-peer credentials. The registry
     can — it stores a token per server, and PeerRegistry.refresh hands it out — so
     the way out is discovery, not a longer env line. The PUT below is that half."
  fi
fi

# ==== the registry half ======================================================
#
# The same operation, expressed where discovery can see it. An agent that resolves
# peers through the sync store gets this token without any env file at all, which is
# what makes per-peer credentials possible and what makes a new peer appear without
# reconciling anything.
#
# Last, and best-effort. The env map above is what an already-deployed agent reads,
# so it must not be rolled back because a registry is down.

if [ "$NO_REGISTRY" = "1" ]; then
  ok "skipping the registry (--no-registry)"
elif [ -z "$ADMIN" ]; then
  warn "no sync-store token for 'amber' in $SECRETS_FILE, so the registry half was
     skipped. The env map above still wires this link."
elif ! registry_ready; then
  warn "the registry is not answering, so the token was not published to it. The env
     map above still wires this link; re-run this when the store is back to make
     the peer discoverable without an env file."
else
  # The token goes in on stdin, as JSON built by yq rather than by string
  # concatenation, so a token containing a quote cannot break out of the document.
  # It is never an argument, so `ps` on this box cannot show it.
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would PUT $(sync_store_base_url)/servers/$TO/token"
  elif TOKEN="$TOKEN" yq -n -o=json '{"token": strenv(TOKEN)}' \
      | curl -fsS -X PUT "$(sync_store_base_url)/servers/$TO/token" \
        -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
        --data @- >/dev/null 2>&1; then
    ok "published '$TO's peer credential to the registry"
  else
    warn "could not publish '$TO's token to the registry — it answered an error, or
     '$TO' has not registered yet. The env map above still wires this link."
  fi
fi

# ==== what is still needed ===================================================

echo
if dry; then
  ok "rehearsal only — $SECRETS_FILE was not written"
else
  warn "$FROM is still running with its OLD configuration. secrets.yaml is the
     source; the container reads a rendered .env. To land this:
         install/install.sh --app $FROM
     (declare.sh --reconcile is config-only and will NOT render or restart.)"
fi
