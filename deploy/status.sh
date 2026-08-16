#!/usr/bin/env bash
#
# What is deployed on this box, as one JSON document.
#
# The read-only counterpart to install.sh. Every other script in this repo narrates
# to a human at 2am; this one answers a program — Aperture's Servers tab renders it
# directly. That is the whole reason it exists: a GUI that screen-scraped the colour
# codes and prose of install.sh would encode "what a healthy box looks like" in
# TypeScript, three repos away from the scripts that decide it.
#
#   deploy/status.sh --json | jq .
#
# The document carries a `schema` number. Bump it whenever a *consumer-visible* field
# is added or changes meaning. A client reading an older document cannot tell a field
# that is absent from one that is false, so without this a stale script on a server
# shows up as "everything is missing" — a screen that is wrong, stuck, and gives no
# hint that the script is what needs updating.
#
# Strictly read-only. It never calls `run`, never writes, and is safe to poll. It
# also never exits non-zero for a *finding* — a missing container, an unreachable
# store and an unreadable secrets file are all reported inside the document, because
# a status command that dies has told you nothing about the other twelve things.
#
# Schema 10 adds the registry's key list from BOTH sides — what secrets.yaml declares
# and what the running container was actually started with — as fingerprints, plus
# `startedAt` per container. Those are what let a client say *why* an app is
# unregistered instead of listing the four things it might be.
#
# Schema 12 adds PEERING, which is a different relation from registration and was
# invisible here. An app can be registered, healthy and mounting its MCP server —
# every green light schema 10 could show — while the one agent that matters cannot
# call it, because that agent's peer map is empty or presents the wrong bearer. That
# is not a degraded state anywhere: an empty peer map means the peer is offered as no
# tools at all, with no error on either side.
#
# So each app now reports both directions: `peers` (who it calls, as names and public
# URLs, read from its LIVE .env), `peerTokenFingerprint` (the digest of the single
# bearer it presents to them), and `bearerKeys` (who it accepts, per token list, as
# name + digest). A link is sound when the caller's fingerprint equals the digest of
# the callee's entry named after the caller — two digests, compared, disclosing
# neither. `syncStore.servers[].tokenFp` is the same comparison for the discovery
# path, where the credential comes from the registry rather than an env file.
#
# Key names come from each manifest, by `kind`, never from a prefix rule: Bloom keeps
# two bearer lists on purpose (peer agents vs the GUI), so choosing between them by
# name would be a guess about what a leaked token buys.
#
# Without privilege to read /etc/amber-infra/secrets.yaml it still works: it reports
# `secretsReadable: false` and falls back to what Docker alone can say. The one thing
# it will not do is print a secret. Values under `apps.*.env` and every token are
# dropped structurally — only key NAMES are emitted, so the GUI can say that
# AMBER_OPENAI_API_KEY is set without ever having seen it.
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

SECRETS_FILE="${SECRETS_FILE:-/etc/amber-infra/secrets.yaml}"
HISTORY="/var/lib/amber-infra/deploy-history"
CADDY_SNIPPETS="${CADDY_ETC:-/etc/caddy}/snippets"
ETC="/etc/amber-infra"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    shift ;;  # the only output format; accepted so the call reads well
    --secrets) SECRETS_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

require_cmd jq

# Findings that are worth surfacing but must not stop the report.
WARNINGS='[]'
note() { WARNINGS="$(printf '%s' "$WARNINGS" | jq -c --arg m "$1" '. + [$m]')"; }

# --- json helpers ------------------------------------------------------------

jstr() { jq -Rn --arg v "$1" '$v'; }  # a correctly escaped JSON string

jnul() {  # a JSON string, or null when empty
  if [ -n "${1:-}" ]; then jstr "$1"; else echo null; fi
}

sget() {  # sget YQ_PATH [default] — "" rather than a fatal error when unavailable
  local path="$1" default="${2:-}" value
  if [ "${SECRETS_READABLE:-false}" != "true" ]; then echo "$default"; return 0; fi
  value="$(yq -r "$path" "$SECRETS_FILE" 2>/dev/null || true)"
  if [ "$value" = "null" ]; then value=""; fi
  echo "${value:-$default}"
}

http_status() {  # http_status URL -> the code, or "" when nothing answered
  curl -fsS -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null || true
}

# --- key fingerprints --------------------------------------------------------
# The one thing this document could not previously say: which key list the registry
# container is *actually running*. It reads SYNC_STORE_KEYS once, at startup, so a
# token minted afterwards is one it has never heard of — and the only symptom is a
# 401 that agent_mcp's register() swallows. Comparing the running list against the
# declared one turns that from a guess into a fact.
#
# Emitting the tokens themselves is obviously out. Emitting a fingerprint is not:
# eight hex of a sha256 identifies a key well enough to *compare* two lists while
# being no step at all toward reconstructing it. The convention is already in the
# store — sync-store/app/auth.py:66 labels a bare token exactly this way.

fingerprint() {  # fingerprint TOKEN -> 8 hex chars, or "" if nothing here can hash
  # Empty in, empty out. Without this an unset token hashes to e3b0c442 — a perfectly
  # valid-looking digest that would read as "this app has a key" and compare unequal
  # to every real one, i.e. the wrong diagnosis with total confidence.
  [ -n "${1:-}" ] || return 0
  if   have sha256sum; then printf '%s' "$1" | sha256sum      | cut -c1-8
  elif have shasum;    then printf '%s' "$1" | shasum -a 256  | cut -c1-8
  elif have openssl;   then printf '%s' "$1" | openssl dgst -sha256 -r | cut -c1-8
  fi
}

# A `name:token,name:token` list reduced to [{name, fp}].
#
# The token lives in a shell local and dies there: only $name and the digest are ever
# handed to jq. Read from a process substitution rather than a heredoc, because bash
# spills a heredoc to a temp file on some builds and that file would hold every key.
#
# Entry parsing mirrors agent_mcp.parse_keys (sync-store/app/auth.py:71) — an entry
# with no colon is a bare token, whose caller label *is* its fingerprint.
key_list_json() {  # key_list_json "a:tok,b:tok" -> [{"name":…,"fp":…}]
  local raw="$1" entry name token fp ph out='[]'
  # `|| [ -n "$entry" ]` is not optional: `tr` leaves the final entry unterminated, and
  # a bare `while read` drops it. Without this the LAST key in every list vanishes —
  # silently, and most often it is the app just installed.
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      *:*) name="${entry%%:*}"; token="${entry#*:}" ;;
      *)   name="";             token="$entry"      ;;
    esac
    [ -n "$token" ] || continue
    fp="$(fingerprint "$token")"
    [ -n "$name" ] || name="sha256:$fp"
    # A CHANGEME token is a distinct finding with a distinct fix: the key was never
    # filled in, so reloading the registry would only teach it the placeholder.
    case "$token" in *CHANGEME*) ph=true ;; *) ph=false ;; esac
    out="$(printf '%s' "$out" \
      | jq -c --arg n "$name" --arg f "$fp" --argjson p "$ph" '. + [{name: $n, fp: $f, placeholder: $p}]')"
  done < <(printf '%s' "$raw" | tr ',' '\n')
  printf '%s' "$out"
}

# A `name=url,name=url` peer map reduced to [{name, baseUrl, endpoint}].
#
# Not a secret: it is a list of names and public hostnames, which is why it can be
# reported as VALUES while every token beside it is reduced to a digest. That
# distinction is the whole reason a client can diagnose peering at all — one half of
# the pairing is safe to show, and comparing a shown URL against a registered one is
# how a mistyped host becomes visible instead of presenting as "the peer is down".
#
# `endpoint` is what agent_runtime's MCPClient will actually open, computed here by
# the same rule it uses (base + /mcp + a trailing slash). A base URL that already
# ends in /mcp — the single most common way to write this by hand — produces
# /mcp/mcp/ there and a 404 that reads as a dead peer, so the resolved endpoint is
# reported rather than left to be imagined from the base.
peer_map_json() {  # peer_map_json "a=https://x,b=https://y" -> [{"name":…,"baseUrl":…}]
  local raw="$1" entry name url out='[]'
  # `|| [ -n "$entry" ]` for the same reason key_list_json needs it: tr leaves the
  # final entry unterminated and a bare `while read` drops it — which here would hide
  # the most recently added peer, i.e. the one being debugged.
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in
      *=*) name="${entry%%=*}"; url="${entry#*=}" ;;
      # load_static_peers logs and skips an entry with no `=`. Reported the same way
      # rather than dropped, so a malformed line is visible instead of merely absent.
      *)   name="$entry";       url=""            ;;
    esac
    [ -n "$name" ] || continue
    out="$(printf '%s' "$out" | jq -c --arg n "$name" --arg u "$url" '
      ($u | sub("/$"; "")) as $trimmed |
      . + [{
        name: $n,
        baseUrl: $u,
        endpoint: (if $trimmed == "" then null
                   elif ($trimmed | endswith("/mcp")) then $trimmed + "/"
                   else $trimmed + "/mcp/" end)
      }]')"
  done < <(printf '%s' "$raw" | tr ',' '\n')
  printf '%s' "$out"
}

# The value of one key in a rendered .env, without it ever reaching the output.
#
# Reads the LIVE file rather than secrets.yaml on purpose: secrets.yaml is the source
# and the container is running on whatever was rendered from it last. When those two
# disagree — which is exactly the state right after a peer is wired and before the app
# is reconciled — only this one describes the behaviour you are seeing.
rendered_env_value() {  # rendered_env_value ENV_FILE KEY
  [ -r "${1:-}" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 | sed -e 's/^"//' -e 's/"$//'
}

# ==== secrets ================================================================
# Deliberately not install/lib/secrets.sh: every read there dies on a missing or
# unreadable file. That is the correct choice for an installer and the wrong one for
# a status command, which must still describe the other half of the box.

SECRETS_PRESENT=false
SECRETS_READABLE=false
[ -f "$SECRETS_FILE" ] && SECRETS_PRESENT=true

if [ -r "$SECRETS_FILE" ] && have yq; then
  SECRETS_READABLE=true
elif [ "$SECRETS_PRESENT" = "true" ] && ! have yq; then
  note "yq (v4) is not installed, so $SECRETS_FILE cannot be read."
elif [ "$SECRETS_PRESENT" = "true" ]; then
  note "secrets.yaml exists but is not readable as this user — domains, pinned images and env key names are unavailable. Re-run with sudo for the full picture."
else
  note "no secrets file at $SECRETS_FILE — this box has not been through install.sh."
fi

# Which values are still placeholders, split by who can fill them.
#
# Generatable, because nothing outside this box constrains the value:
#
#   * `CHANGEME-openssl-rand-hex-32` — the placeholder text is the recipe;
#   * a bare `CHANGEME` inside a `*_KEYS` value — those are bearer tokens other
#     agents present to this app's MCP server, and `agent_mcp.parse_keys` takes any
#     string after the `name:`. They are not spelled with the `-openssl-` suffix only
#     because the value is a compound `name:tok,name:tok` string.
#
# Everything else is an API key whose value exists somewhere else in the world.
#
# The split is what lets a setup screen offer a button for one group and a shopping
# list for the other, instead of one undifferentiated list of nine things. It also
# stops a `*_KEYS` placeholder being mistaken for something a human must supply and
# therefore left in place — `secrets_render_env` does not check for placeholders, so
# that word ends up mounted as a live bearer token on a public endpoint.
PLACEHOLDERS_GEN='[]'
PLACEHOLDERS_MANUAL='[]'
if [ "$SECRETS_READABLE" = "true" ] && have jq; then
  SECRETS_JSON="$(yq -o=json '.' "$SECRETS_FILE" 2>/dev/null || echo '{}')"
  ALL_PATHS="$(printf '%s' "$SECRETS_JSON" \
    | jq -c '[paths(type == "string" and test("CHANGEME")) | join(".")]' 2>/dev/null || echo '[]')"
  # Decided on the value for the first kind and on the last path segment for the
  # second, so `apps.amber.env.AMBER_MCP_KEYS` is recognised wherever it appears.
  #
  # "Generatable" is not one command. The placeholder value says which:
  # CHANGEME-openssl-rand-hex-32 means `openssl rand -hex 32`, and
  # CHANGEME-fernet-generate-key means a Fernet key — 32 bytes of urlsafe base64,
  # which Bloom validates at startup and which a hex string is not. A setup screen
  # offering one button for this whole group will hand someone a value the service
  # refuses to boot with, so branch on the placeholder, not on the category.
  # The `_KEYS$` arm is a *name* rule, so on its own it captures any placeholder that
  # happens to sit in a key ending `_KEYS` — including BLOOM_FERNET_KEYS, whose value
  # is `CHANGEME-fernet-generate-key`. That is the exact mistake the paragraph above
  # warns about, and it was live: the setup screen offered it, and the generator wrote
  # 32 hex bytes into a slot Bloom rejects at startup. So the name rule is narrowed to
  # a *bare* CHANGEME, which is the only shape the compound `name:tok` case ever has.
  # A `CHANGEME-<recipe>` value is claimed by the recipe that names it, or by nothing.
  GEN_PATHS="$(printf '%s' "$SECRETS_JSON" | jq -c '
      [paths(type == "string" and test("CHANGEME")) as $p
       | select((getpath($p) | test("CHANGEME-openssl-rand-hex"))
                or (($p[-1] | tostring | test("_KEYS$"))
                    and (getpath($p) | test("CHANGEME([^-]|$)"))))
       | $p | join(".")]' 2>/dev/null || echo '[]')"
  # install.sh recomputes these on every run, so a placeholder in one is not a task —
  # listing it would send someone hunting for a value that is about to be overwritten.
  DERIVED_PATHS="$(printf '%s' "$SECRETS_JSON" | jq -c '
      [paths(type == "string" and test("CHANGEME")) as $p
       | select($p[-1] | tostring
                | test("(_PUBLIC_URL|_SYNC_STORE_URL|_SYNC_STORE_TOKEN)$") or . == "AMBER_UPDATE_COMMAND")
       | $p | join(".")]' 2>/dev/null || echo '[]')"
  PLACEHOLDERS_GEN="$GEN_PATHS"
  PLACEHOLDERS_MANUAL="$(printf '%s' "$ALL_PATHS" \
    | jq -c --argjson gen "$GEN_PATHS" --argjson derived "$DERIVED_PATHS" '. - $gen - $derived')"
fi

# Two settings that are not CHANGEME but are still the example's values, and both
# break ACME silently if left. Reported so a setup screen can say so.
ACME_EMAIL="$(sget '.infra.acme_email')"
case "$ACME_EMAIL" in ''|*example.com) ACME_SET=false ;; *) ACME_SET=true ;; esac

# ==== the registry ===========================================================
# Queried once with amber's key; every app's registration state is then read out of
# this one response rather than re-fetched per app.

SYNC_URL="$(sget '.sync_store.url')"
SYNC_PORT="$(sget '.sync_store.port' 8081)"
SYNC_LOCAL="http://127.0.0.1:$SYNC_PORT"
SYNC_TOKEN=""
if [ "$SECRETS_READABLE" = "true" ]; then
  SYNC_TOKEN="$(yq -r '.sync_store.keys[] | select(.name == "amber") | .token' "$SECRETS_FILE" 2>/dev/null | head -n1 || true)"
  if [ "$SYNC_TOKEN" = "null" ]; then SYNC_TOKEN=""; fi
fi

# Why the store is not answering, specifically.
#
# `curl -fsS` fails on any non-2xx, so one message stood in for four different
# problems with four different fixes: not deployed, not running, running but not
# listening, and running but rejecting the credential. The last reads most like a
# network fault and is not — a 401 means the token in secrets.yaml is not the token
# the container was STARTED with, which is what happens whenever keys are regenerated
# without restarting it.
SYNC_REACHABLE=false
SYNC_SERVERS='[]'
SYNC_STATE="$(container_state sync-store)"
SYNC_DETAIL=""

if [ -z "$SYNC_TOKEN" ]; then
  if [ "$SECRETS_READABLE" = "true" ]; then
    SYNC_DETAIL="no token for 'amber' in sync_store.keys"
    note "no sync-store token for 'amber' in secrets.yaml — the registry cannot be queried."
  fi
elif [ "$SYNC_STATE" = "missing" ]; then
  SYNC_DETAIL="not deployed on this box"
  note "the sync-store is not deployed on this box yet, so nothing has registered. install.sh brings it up on a core box."
elif [ "$SYNC_STATE" != "running" ]; then
  SYNC_DETAIL="container is $SYNC_STATE"
  note "the sync-store container is $SYNC_STATE, not running. See: docker logs sync-store --tail 50"
else
  # It is running, so ask it on loopback. Going through the public URL first would
  # fold DNS, Caddy and TLS into a question about the store itself.
  LOCAL_HEALTH="$(http_status "$SYNC_LOCAL/health")"
  if [ "$LOCAL_HEALTH" != "200" ]; then
    SYNC_DETAIL="running but not answering on $SYNC_LOCAL/health"
    note "the sync-store container is running but nothing answers on $SYNC_LOCAL/health (got ${LOCAL_HEALTH:-no response}). It may still be starting, or bound to a port other than sync_store.port. Check: docker logs sync-store --tail 50"
  else
    SERVERS_BODY="$(mktemp)"
    SERVERS_CODE="$(curl -s -o "$SERVERS_BODY" -m 6 -w '%{http_code}' -H "Authorization: Bearer $SYNC_TOKEN" "$SYNC_LOCAL/servers" 2>/dev/null || true)"
    case "$SERVERS_CODE" in
      200)
        SYNC_REACHABLE=true
        # The store answers either {"servers":[…]} or a bare array. Accept both,
        # exactly as agent-mcp-py's PeerRegistry.refresh does.
        # `tokenFp` is the OTHER half of peering, and the half that has never been
        # visible from anywhere. The store holds a per-server credential, set only
        # by PUT /servers/{name}/token, and hands it out on discovery — it is what
        # agent_mcp's PeerRegistry.refresh loads and what agent_runtime's MCP client
        # sends as the outbound Authorization. So an agent resolving peers through
        # discovery presents THIS, not the one in its own env file, and the two can
        # disagree with nothing anywhere saying so.
        #
        # Reduced to a digest before it enters the document, exactly like every other
        # token here: `has("token")` distinguishes "the store set none" from "this
        # store is too old to report one", which a bare `// ""` could not.
        SYNC_SERVERS="$(jq -c '(.servers // .) | map({
            name: .name,
            baseUrl: (.base_url // ""),
            lastSeen: (.last_seen // null),
            stale: (.stale // false),
            tokenSet: (has("token") and ((.token // "") != "")),
            token: (.token // "")
          })' "$SERVERS_BODY" 2>/dev/null || echo '[]')"
        # The digest is computed in shell, not jq — jq has no sha256 — and the raw
        # token is dropped in the same pass, so it exists only inside this loop.
        SYNC_SERVERS="$(
          printf '%s' "$SYNC_SERVERS" | jq -c '.[]' 2>/dev/null | while IFS= read -r row; do
            printf '%s' "$row" | jq -c --arg fp \
              "$(fingerprint "$(printf '%s' "$row" | jq -r '.token // ""')")" \
              'del(.token) + {tokenFp: (if $fp == "" then null else $fp end)}'
          done | jq -sc '.'
        )"
        ;;
      401)
        SYNC_DETAIL="healthy, but rejecting amber's token"
        note "the sync-store is running and healthy but returned 401 for amber's token. The container reads SYNC_STORE_KEYS from its env file at STARTUP, so a token regenerated in secrets.yaml since then is not the one it is checking against. Re-run install.sh here, or: docker compose -f /etc/amber-infra/sync-store/docker-compose.prod.yml up -d --force-recreate"
        ;;
      *)
        SYNC_DETAIL="healthy, but /servers returned ${SERVERS_CODE:-no response}"
        note "the sync-store is healthy but GET /servers returned ${SERVERS_CODE:-no response}. Check: docker logs sync-store --tail 50"
        ;;
    esac
    rm -f "$SERVERS_BODY"
  fi
fi

# The key list, from both sides, so a consumer can tell the four unregistered causes
# apart instead of naming all four and hoping.
#
#   declared but not running -> the store was started before this key existed
#   fingerprints disagree    -> the token was rotated since the store started
#   both agree, not in /servers -> the app's own problem (prefix, public URL, booting)
#
# `readable` is true only when BOTH sides were actually read. An empty list from an
# unreadable secrets file and an empty list from a store with no keys are the same
# JSON and emphatically not the same finding.
SYNC_KEYS_READABLE=false
SYNC_KEYS_RUNNING='[]'
SYNC_KEYS_DECLARED='[]'
SYNC_STARTED_AT=""
SYNC_RUNNING_OK=false
SYNC_DECLARED_OK=false

# What the registry is pinned to, and what it is actually running.
#
# Reported for the same reason every app reports the pair: the two can disagree, and
# that disagreement is invisible from either file alone. It matters more here than for
# an app, because `ensure_sync_store` writes the image into the deployed compose file
# only when it first creates it — so a bumped `sync_store.image` sits there looking
# applied, and the next fresh install is where you find out it never was.
SYNC_IMAGE_PINNED="$(sget '.sync_store.image')"
SYNC_IMAGE_DEPLOYED=""
SYNC_IMAGE_RUNNING=""
[ -f "$ETC/sync-store/docker-compose.prod.yml" ] \
  && SYNC_IMAGE_DEPLOYED="$(grep -E '^\s*image:' "$ETC/sync-store/docker-compose.prod.yml" \
       | head -n1 | sed -E 's/^\s*image:\s*//; s/\s*$//' || true)"

if have docker && [ "$SYNC_STATE" != "missing" ]; then
  SYNC_IMAGE_RUNNING="$(docker container inspect -f '{{.Config.Image}}' sync-store 2>/dev/null || true)"
  SYNC_STARTED_AT="$(docker container inspect -f '{{.State.StartedAt}}' sync-store 2>/dev/null || true)"
  case "$SYNC_STARTED_AT" in 0001-01-01*) SYNC_STARTED_AT="" ;; esac
  # `container inspect`, never bare `inspect` — see the note in app_json.
  SYNC_RUNNING_RAW="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sync-store 2>/dev/null \
    | sed -n 's/^SYNC_STORE_KEYS=//p' | head -n1 || true)"
  if [ -n "$SYNC_RUNNING_RAW" ]; then
    SYNC_KEYS_RUNNING="$(key_list_json "$SYNC_RUNNING_RAW")"
    SYNC_RUNNING_OK=true
  fi
  unset SYNC_RUNNING_RAW
fi

if [ "$SECRETS_READABLE" = "true" ]; then
  # The same expression secrets_sync_store_keys renders into the env file, so the two
  # sides of the comparison are produced the way install.sh produces the real one.
  SYNC_DECLARED_RAW="$(yq -r '.sync_store.keys[]? | .name + ":" + .token' "$SECRETS_FILE" 2>/dev/null \
    | paste -sd, - || true)"
  if [ -n "$SYNC_DECLARED_RAW" ]; then
    SYNC_KEYS_DECLARED="$(key_list_json "$SYNC_DECLARED_RAW")"
    SYNC_DECLARED_OK=true
  fi
  unset SYNC_DECLARED_RAW
fi

if [ "$SYNC_RUNNING_OK" = "true" ] && [ "$SYNC_DECLARED_OK" = "true" ]; then
  SYNC_KEYS_READABLE=true
  # Worth a warning of its own: this is the state that makes an app look broken when
  # the registry is the thing that needs restarting.
  # Declared keys the running store either does not have, or has under a different
  # fingerprint. Absent and stale are the same finding here: both are rejected.
  SYNC_KEYS_DRIFT="$(jq -nc --argjson r "$SYNC_KEYS_RUNNING" --argjson d "$SYNC_KEYS_DECLARED" '
      ($r | map({key: .name, value: .fp}) | from_entries) as $run
      | [ $d[] | select($run[.name] != .fp) | .name ]' 2>/dev/null || echo '[]')"
  if [ "$(printf '%s' "$SYNC_KEYS_DRIFT" | jq -r 'length')" != "0" ]; then
    note "the sync-store is running an older key list than secrets.yaml declares ($(printf '%s' "$SYNC_KEYS_DRIFT" | jq -r 'join(", ")')). SYNC_STORE_KEYS is read at STARTUP, so those keys are rejected until it reloads: bash deploy/reload-registry.sh"
  fi
  unset SYNC_KEYS_DRIFT
fi

# The image equivalent of the key drift above, and it hides in exactly the same way:
# secrets.yaml is what a fresh install reads, the deployed compose is what runs, and
# `ensure_sync_store` stops touching the compose file after the first create — so
# editing the pin by hand looks applied and is not.
if [ "$SECRETS_READABLE" = "true" ] && [ -n "$SYNC_IMAGE_PINNED" ] && [ -n "$SYNC_IMAGE_DEPLOYED" ] \
   && [ "$SYNC_IMAGE_PINNED" != "$SYNC_IMAGE_DEPLOYED" ]; then
  note "secrets.yaml pins the sync-store to $SYNC_IMAGE_PINNED but the deployed compose runs $SYNC_IMAGE_DEPLOYED. A reinstall would roll it to the pin: bash deploy/update-sync-store.sh --to ${SYNC_IMAGE_PINNED##*:}"
fi

# ==== which box is this ======================================================
# `infra.server` labels this box; `apps.<name>.server` says which box an app belongs
# on. Nothing in this repo consumed either field before now — `server:` was a comment
# with syntax. It gets a meaning here so that a two-server split stops being something
# you hold in your head.
#
# Defaulted from `role` when unset, so an existing secrets.yaml keeps working: core is
# server a, app is server b, which is what the README already describes.
#
# An app whose `server` is unset, or whose value matches nothing, is treated as
# BELONGING HERE. Deciding otherwise would hide an app from the only screen that could
# tell you it exists, on the strength of a field that until today meant nothing.

SERVER_LABEL="$(sget '.infra.server')"
if [ -z "$SERVER_LABEL" ]; then
  case "$(sget '.infra.role' core)" in
    core) SERVER_LABEL=a ;;
    *)    SERVER_LABEL=b ;;
  esac
fi

# The domain is written down in three places and they must agree.
#
# `infra.primary_domain` is the apex, `sync_store.url` is what every app is told to
# register against, and each `apps.*.domain` is what Caddy requests a certificate for.
# Nothing derives one from another, so updating the apex and stopping there leaves two
# stale hostnames — and both fail quietly rather than loudly: the certificate is for a
# name you do not own, and discovery points at a host nobody is listening on.
PRIMARY="$(sget '.infra.primary_domain')"
if [ -n "$PRIMARY" ] && [ "$SECRETS_READABLE" = "true" ]; then
  EXPECTED_SYNC="https://sync.$PRIMARY"
  ACTUAL_SYNC="$(sget '.sync_store.url')"
  if [ -n "$ACTUAL_SYNC" ] && [ "$ACTUAL_SYNC" != "$EXPECTED_SYNC" ]; then
    note "sync_store.url is $ACTUAL_SYNC but install.sh serves the store at $EXPECTED_SYNC. Apps will register against a host that is not being served."
  fi
  while IFS= read -r _app; do
    [ -n "$_app" ] || continue
    # Only apps that belong HERE. Another box's app gets its certificate on that box,
    # from that box's secrets.yaml — warning about it here is noise about work that is
    # not yours to do, on a screen whose whole job is to say what is.
    _srv="$(sget ".apps.\"$_app\".server")"
    if [ -n "$_srv" ] && [ "$_srv" != "$SERVER_LABEL" ]; then continue; fi
    _dom="$(sget ".apps.\"$_app\".domain")"
    [ -n "$_dom" ] || continue
    case "$_dom" in
      *".$PRIMARY") ;;
      *) note "apps.$_app.domain is $_dom, which is not under $PRIMARY. If the apex was changed without updating this, Caddy will request a certificate for a name you do not own." ;;
    esac
  done < <(yq -r '.apps // {} | keys | .[]' "$SECRETS_FILE" 2>/dev/null || true)
fi


# ==== dns ====================================================================
# Do the records this box needs actually point at it?
#
# Listing what you need is not the same as checking it, and the difference is the
# whole cost: Caddy asks for a certificate the moment a site block appears, and
# Let's Encrypt rate-limits failures per domain. install.sh checks this in preflight,
# but by then you are already running an install. Doing it here means the answer is
# on screen before you decide to.
#
# Every name is resolved through this box's own resolver, which is the one Caddy will
# use — checking from anywhere else would be answering a different question.

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"

dns_record_json() {  # dns_record_json NAME WHY
  local name="$1" why="$2" addresses points_here=false
  addresses="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  if [ -n "$PUBLIC_IP" ] && printf '%s' "$addresses" | grep -qx "$PUBLIC_IP"; then
    points_here=true
  fi
  jq -n \
    --arg     name      "$name" \
    --arg     why       "$why" \
    --argjson points    "$points_here" \
    --argjson addresses "$(printf '%s' "$addresses" | sed '/^$/d' | jq -Rn '[inputs]')" \
    '{name: $name, why: $why, addresses: $addresses, pointsHere: $points}'
}

dns_json() {
  {
    if [ "$SECRETS_READABLE" = "true" ]; then
      while IFS= read -r _a; do
        [ -n "$_a" ] || continue
        _s="$(sget ".apps.\"$_a\".server")"
        [ -z "$_s" ] || [ "$_s" = "$SERVER_LABEL" ] || continue
        _d="$(sget ".apps.\"$_a\".domain")"
        [ -n "$_d" ] && dns_record_json "$_d" "$_a"
      done < <(yq -r '.apps // {} | keys | .[]' "$SECRETS_FILE" 2>/dev/null || true)
    fi
    if [ "$(sget '.infra.role' core)" = "core" ] && [ -n "$PRIMARY" ]; then
      dns_record_json "sync.$PRIMARY" "the registry"
    fi
  } | jq -sc '.'
}

DNS_RECORDS="$(dns_json)"

# ==== the catalogue ==========================================================
# What this checkout can install: every directory carrying a docker-compose.prod.yml.
#
# The repo is the catalogue. install.sh already refuses any app without one of these,
# so their presence is not a hint, it is the definition — and the file carries the
# pinned image and the loopback port too, which is everything an install needs except
# a hostname.
#
# caddy and sync-store are excluded: they are the edge and the registry, brought up by
# ensure_caddy and ensure_sync_store, and `install.sh --app sync-store` is not a thing.

#: Not apps. The edge and the registry are brought up by ensure_caddy and
#: ensure_sync_store as part of installing whatever app you asked for; there is no
#: `install.sh --app sync-store`, their config lives under `caddy:`/`sync_store:`
#: rather than `apps:`, and neither is an MCP server so neither ever registers.
#:
#: Listing them as apps is not cosmetic. The card offers Rename, Roll back and
#: "Save domain" — and those write to `apps.sync-store.*`, which nothing reads.
INFRA_SERVICES="caddy sync-store"

is_infra_service() {  # is_infra_service NAME
  case " $INFRA_SERVICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# The app's own account of what it needs, passed through rather than interpreted.
#
# Read with yq and reshaped with jq rather than through install/lib/manifest.sh, for
# two reasons. That library's accessors are line-oriented, so every field would be a
# round trip back through shell on its way to becoming JSON again; and its
# `manifest_check` can `die`, which this script must never do for a finding.
#
# The only semantics applied here are the two that have to hold everywhere: `required`
# defaults to true, and `secret` may only be raised.
#
# `null` when the app has no manifest. A consumer must be able to tell "this app has
# not been described" from "it was described as needing nothing".
manifest_json() {  # manifest_json NAME
  local path="$REPO_ROOT/$1/manifest.yaml"
  [ -r "$path" ] || { echo null; return 0; }
  yq -o=json '.' "$path" 2>/dev/null | jq -c '{
    version:   (.manifest // 0),
    envPrefix: ((.env_prefix // "") | sub("_$"; "")),
    role:      (.role // null),
    release:   (if .release then {repo: (.release.repo // null), package: (.release.package // null)} else null end),
    # Keys declared by PATTERN rather than by name: the per-provider OAuth client
    # credentials, whose set is a directory of TOMLs inside the image. Emitted so the
    # GUI can offer to add one without this repo having heard of that provider.
    # (No apostrophes in here — the whole jq program is a single-quoted shell string.)
    dynamicKeys: [ (.dynamic_keys // [])[] | {
      prefix:   .prefix,
      label:    (.label // .prefix),
      discover: (.discover // null),
      why:      (.why // null)
    } ],
    keys: [ (.keys // [])[] | {
      name:       .name,
      # An unknown kind degrades rather than throws: a box reading a newer manifest
      # must still render, and "somebody has to supply this" is the safe reading.
      kind:       (.kind // "supplied"),
      credential: (.credential // null),
      label:      (.label // .name),
      helpUrl:    (.help_url // null),
      why:        (.why // null),
      group:      (.group // null),
      source:     (.source // null),
      # has(), not `//`: an explicit false is not an absent field, and `//` cannot
      # tell them apart.
      default:    (if has("default")  then .default  else null end),
      required:   (if has("required") then .required else true end),
      secret:     ((.secret // false) or (.name | test("(_KEY|_KEYS|_TOKEN|_SECRET|_PASSWORD|_PASS)$"))),
      # The three fields that describe cross-app wiring rather than one app.
      #
      # `peers` on a generated:token key is the list of CALLERS this app expects to
      # hear from — the `name:` halves of its compound bearer list. `peerOf`/`peerKey`
      # on a peer_token key are the other direction: which app holds the matching
      # value, and under which key.
      #
      # Emitted because a client cannot otherwise tell which of several token lists on
      # one app is the one a given peer presents to. Bloom has two — BLOOM_MCP_KEYS
      # for agents and BLOOM_ADMIN_KEYS for the GUI — deliberately separate, so a
      # guess between them is a guess about what a leaked token would buy.
      peers:      (.peers // []),
      peerOf:     (.peer_of // null),
      peerKey:    (.peer_key // null)
    } ]
  }' 2>/dev/null || echo null
}

catalogue_json() {
  local dir name compose image upstream
  for dir in "$REPO_ROOT"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    is_infra_service "$name" && continue
    compose="${dir}docker-compose.prod.yml"
    [ -f "$compose" ] || continue
    image="$(image_of "$compose")"
    upstream="$(grep -oE '127\.0\.0\.1:[0-9]+' "$compose" | head -n1 || true)"
    jq -n --arg name "$name" \
          --argjson image "$(jnul "$image")" \
          --argjson upstream "$(jnul "$upstream")" \
          --argjson manifest "$(manifest_json "$name")" \
          '{name: $name, image: $image, upstream: $upstream, manifest: $manifest}'
  done | jq -sc '.'
}

CATALOGUE="$(catalogue_json)"

# ==== apps ===================================================================
# The union of what secrets.yaml declares and what is actually deployed under
# /etc/amber-infra, so an app stood up by hand still appears rather than being
# quietly absent from a screen that claims to list everything.

app_names() {
  # Declared in config, deployed on disk, or available in the checkout. All three,
  # because each answers a different question and an app can be in any one of them
  # alone: inherited from an old example, stood up by hand, or shipped in the repo
  # and not installed yet.
  if [ "$SECRETS_READABLE" = "true" ]; then
    yq -r '.apps // {} | keys | .[]' "$SECRETS_FILE" 2>/dev/null | while IFS= read -r _n; do
      is_infra_service "$_n" || printf '%s
' "$_n"
    done
  fi
  local dir name
  for dir in "$ETC"/*/; do
    [ -d "$dir" ] || continue
    [ -e "${dir}docker-compose.prod.yml" ] || continue
    name="$(basename "$dir")"
    is_infra_service "$name" && continue
    printf '%s
' "$name"
  done
  printf '%s' "$CATALOGUE" | jq -r '.[].name'
}

# The editable source of an app's environment: `apps.<name>.env` in secrets.yaml,
# NOT the rendered .env beside the container. The rendered file is downstream — a GUI
# that wrote to it would be overwritten by the next install.
#
# A value is emitted only when the key name says it is not a secret. `secret` is
# decided by suffix, and the rule is deliberately blunt: anything ending _KEY, _KEYS,
# _TOKEN, _SECRET, _PASSWORD or _PASS is never printed, whatever it holds. `set` and
# `placeholder` still describe it, which is everything an editor needs — you do not
# have to see an API key to replace it, and this script stays safe to poll and log.
app_env_json() {  # app_env_json NAME MANIFEST_JSON
  if [ "$SECRETS_READABLE" != "true" ]; then echo '[]'; return 0; fi
  yq -o=json ".apps.\"$1\".env // {}" "$SECRETS_FILE" 2>/dev/null \
    | jq -c --argjson mf "${2:-null}" '
    def issecret: test("(_KEY|_KEYS|_TOKEN|_SECRET|_PASSWORD|_PASS)$");
    # The name-based rule for "install.sh overwrites this on every run". It stays as
    # the fallback for an app with no manifest, and ONLY as that: a manifest says so
    # outright, and this rule cannot see a fourth derived key like BLOOM_PUBLIC_URL,
    # which is exactly the kind of thing it used to make someone hunt for a value for.
    def isderived:
      test("(_PUBLIC_URL|_SYNC_STORE_URL|_SYNC_STORE_TOKEN)$") or . == "AMBER_UPDATE_COMMAND";
    ($mf.keys // []) as $mk |
    to_entries | map(
      . as $e |
      ($mk | map(select(.name == $e.key)) | first) as $m |
      # The floor: the manifest may raise secrecy, never lower it. A careless manifest
      # cannot talk this script into printing a token.
      (($e.key | issecret) or ($m.secret // false)) as $sec |
      {
        name: $e.key,
        secret: $sec,
        derived: (if $m then ($m.kind == "derived") else ($e.key | isderived) end),
        kind: ($m.kind // null),
        credential: ($m.credential // null),
        label: ($m.label // null),
        required: (if $m then $m.required else true end),
        placeholder: ($e.value | tostring | test("CHANGEME")),
        set: (($e.value | tostring | length) > 0),
        value: (if $sec then null else ($e.value | tostring) end)
      })' 2>/dev/null || echo '[]'
}

app_json() {  # app_json NAME
  local name="$1" dir="$ETC/$1"
  local compose pinned running state health domain upstream http env_file env_keys

  compose="$(find "$dir" -maxdepth 1 -name 'docker-compose*.yml' 2>/dev/null | sort | head -n1 || true)"
  pinned=""
  if [ -n "$compose" ]; then pinned="$(image_of "$compose")"; fi
  if [ -z "$pinned" ]; then pinned="$(sget ".apps.\"$name\".image")"; fi

  # `docker container inspect`, never bare `docker inspect` — see container_health.
  # Bare inspect resolves images, volumes and networks from the same namespace, and on
  # one of those `.State.Status` evaluates to the string "<no value>" with exit 0, so
  # the `|| echo missing` fallback never fires and every consumer reads a container
  # that does not exist as one that does.
  state="$(docker container inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
  # Trimmed, because a client comparing against a known state should not be defeated
  # by whitespace it cannot see.
  state="$(printf '%s' "$state" | tr -d '[:space:]')"
  [ -n "$state" ] || state=missing
  running="$(docker container inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)"
  health="$(container_health "$name")"
  # When it last started. Registration happens on startup and then only every 300s,
  # so "not registered" 20 seconds after a restart and "not registered" an hour after
  # one are different findings, and this is the only field that separates them.
  local started
  started="$(docker container inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null || true)"
  case "$started" in 0001-01-01*) started="" ;; esac

  domain="$(sget ".apps.\"$name\".domain")"
  upstream="$(sget ".apps.\"$name\".upstream")"

  # Assignment, and the two facts that are not runtime state: is it declared in this
  # box's config, and can this checkout install it at all.
  local server declared available this_box
  server="$(sget ".apps.\"$name\".server")"
  declared=false
  if [ "$SECRETS_READABLE" = "true" ] && yq -e ".apps.\"$name\"" "$SECRETS_FILE" >/dev/null 2>&1; then
    declared=true
  fi
  available=false
  if printf '%s' "$CATALOGUE" | jq -e --arg n "$name" 'any(.name == $n)' >/dev/null 2>&1; then
    available=true
  fi
  # Unset, or a label nobody recognises, means here. See the note above SERVER_LABEL.
  this_box=true
  if [ -n "$server" ] && [ "$server" != "$SERVER_LABEL" ]; then this_box=false; fi

  http=""
  if [ -n "$domain" ]; then http="$(http_status "https://$domain/health")"; fi
  if [ "$http" = "000" ]; then http=""; fi

  # Key names only. The `cut` at the `=` is what makes this safe: a value never
  # enters a variable here, let alone the output.
  env_file=""
  env_keys='[]'
  if [ -r "$dir/$name.env" ]; then
    env_file="$dir/$name.env"
    env_keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null | sed 's/=$//' | jq -Rn '[inputs]' || echo '[]')"
  fi

  # The prefix, from all three places it can be known, because the whole class of bug
  # here is those three disagreeing without anyone being told.
  #
  #   manifest  — what the app says it reads. Authoritative.
  #   declared  — apps.<n>.env_prefix in secrets.yaml. Cross-check only.
  #   rendered  — what install.sh actually wrote into the live .env. The ground truth
  #               for a container that is already running.
  #
  # Aperture used to discover the rendered one by SSHing in and grepping this file
  # itself. It is read here, where the file is already open and only key NAMES ever
  # leave: keyed off _SYNC_STORE_URL rather than _PUBLIC_URL because an app may have a
  # second, non-MCP *_PUBLIC_URL — Bloom's OAuth origin — and that one would match too.
  # The fingerprint of the token this app is ACTUALLY presenting, out of its rendered
  # .env. Compared against the sync_store.keys entry of the same name it separates two
  # failures that look identical and have different repairs: the registry never heard
  # of this key (reload the registry) versus the app is still presenting last week's
  # (reconcile the app). Only the digest leaves this function.
  local sync_fp=""
  if [ -r "$env_file" ]; then
    sync_fp="$(fingerprint "$(sed -n 's/^[A-Z][A-Z0-9_]*_SYNC_STORE_TOKEN=//p' "$env_file" 2>/dev/null \
      | head -n1 | tr -d '"')")"
  fi

  # WHY it did not register, from the only place that answer has ever existed.
  #
  # agent_mcp's register() logs and swallows every failure by contract, so the reason
  # never reaches the store, never reaches this document, and never reaches the GUI. It
  # exists solely in the app's own log, and the only way to read it was to SSH in and
  # grep — which is precisely what made "unregistered" a dead end with no next move.
  # sync_store_wait_for_registration already tells you to run this command by hand; this
  # runs it for you.
  #
  # The lines it catches, all of which name a different repair:
  #   "Registered with the sync store at ..."          it worked
  #   "No public URL configured ...; skipping"         never attempted, env is wrong
  #   "Sync store unreachable (...): ..."              attempted and failed, with why
  #   "MCP server disabled (...)"                      the server never mounted at all
  #   "MCP server mounted at /mcp"                     it did mount
  #
  # Bounded and redacted: 400 lines back, last 4 matches, 300 chars each, and any
  # token-shaped run replaced — a third-party exception repr is not something this
  # script controls the contents of, and it is being put on a screen.
  local reg_log='[]'
  if [ "$state" != "missing" ] && have docker; then
    reg_log="$(docker logs "$name" --tail 400 2>&1 \
      | grep -iE 'sync store|mcp server' \
      | tail -n 4 \
      | cut -c1-300 \
      | sed -E 's/[A-Za-z0-9_-]{32,}/<redacted>/g' \
      | jq -Rn '[inputs]' 2>/dev/null || echo '[]')"
    [ -n "$reg_log" ] || reg_log='[]'
  fi

  local manifest env_prefix_declared env_prefix_rendered
  manifest="$(manifest_json "$name")"
  env_prefix_declared="$(sget ".apps.\"$name\".env_prefix")"
  env_prefix_declared="${env_prefix_declared%_}"
  env_prefix_rendered=""
  if [ -r "$env_file" ]; then
    env_prefix_rendered="$(grep -oE '^[A-Z][A-Z0-9_]*_SYNC_STORE_URL=' "$env_file" 2>/dev/null \
      | head -n1 | sed 's/_SYNC_STORE_URL=$//' || true)"
  fi

  # ---- cross-app wiring, from both ends --------------------------------------
  #
  # The failure this reports: an app can be registered, healthy, mounting its MCP
  # server and answering 401 to an unauthenticated probe — every green light this
  # document already had — while being uncallable by the one agent that matters,
  # because that agent's peer map is empty or its bearer does not match. Registration
  # and peering are different relations, and nothing here could tell them apart.
  #
  # Three facts make it decidable, and none of them discloses a token:
  #
  #   peers        — who this app CALLS, as names and public URLs, from its live .env.
  #   peerTokenFp  — the digest of the single bearer it presents to them.
  #   bearerKeys   — who this app ACCEPTS, per token list, as name + digest.
  #
  # A link is sound when the caller's peerTokenFp equals the digest of the callee's
  # entry named after the caller. Two digests, compared — the same trick
  # syncTokenFingerprint uses for registration, applied to the other relation.
  #
  # Key NAMES come from the manifest, by kind, not from a prefix rule. Bloom has two
  # bearer lists on purpose (agents vs the GUI), and choosing between them by name
  # would be guessing about what a leaked token buys.
  local peer_map_key peer_token_key peers_json peer_token_fp bearer_keys
  peer_map_key="$(printf '%s' "$manifest" \
    | jq -r '((.keys // [])[] | select(.kind == "peer_map") | .name), "" ' 2>/dev/null | head -n1)"
  peer_token_key="$(printf '%s' "$manifest" \
    | jq -r '((.keys // [])[] | select(.kind == "peer_token") | .name), "" ' 2>/dev/null | head -n1)"

  peers_json='[]'
  if [ -n "$peer_map_key" ]; then
    peers_json="$(peer_map_json "$(rendered_env_value "$env_file" "$peer_map_key")")"
  fi

  peer_token_fp=""
  if [ -n "$peer_token_key" ]; then
    peer_token_fp="$(fingerprint "$(rendered_env_value "$env_file" "$peer_token_key")")"
  fi

  # Read from secrets.yaml rather than the rendered .env, because this is the half a
  # link is REPAIRED at: connect-peer.sh writes the source, and the callee usually
  # needs no restart for it (agent-mcp-py re-reads nothing, but the value was already
  # correct if the caller was the one being fixed). Comparing the caller's live value
  # against the callee's source is the comparison that says "wired, pending a
  # reconcile" rather than "broken".
  bearer_keys='[]'
  if [ "$SECRETS_READABLE" = "true" ]; then
    local bk_name bk_peers bk_entries
    while IFS= read -r bk_name; do
      [ -n "$bk_name" ] || continue
      bk_peers="$(printf '%s' "$manifest" \
        | jq -c --arg k "$bk_name" '[(.keys // [])[] | select(.name == $k) | .peers // []] | first // []')"
      bk_entries="$(key_list_json "$(sget ".apps.\"$name\".env.\"$bk_name\"")")"
      bearer_keys="$(printf '%s' "$bearer_keys" | jq -c \
        --arg k "$bk_name" --argjson p "$bk_peers" --argjson e "$bk_entries" \
        '. + [{key: $k, peers: $p, entries: $e}]')"
    done < <(printf '%s' "$manifest" \
      | jq -r '(.keys // [])[] | select(.kind == "generated:token") | .name' 2>/dev/null || true)
  fi

  jq -n \
    --arg     name     "$name" \
    --argjson domain   "$(jnul "$domain")" \
    --argjson upstream "$(jnul "$upstream")" \
    --argjson pinned   "$(jnul "$pinned")" \
    --argjson running  "$(jnul "$running")" \
    --arg     state    "$state" \
    --arg     health   "$health" \
    --argjson envFile  "$(jnul "$env_file")" \
    --argjson compose  "$(jnul "$compose")" \
    --argjson startedAt "$(jnul "$started")" \
    --argjson syncFp    "$(jnul "$sync_fp")" \
    --argjson regLog    "$reg_log" \
    --argjson http     "${http:-null}" \
    --argjson envKeys  "$env_keys" \
    --argjson env      "$(app_env_json "$name" "$manifest")" \
    --argjson server   "$(jnul "$server")" \
    --argjson thisBox  "$this_box" \
    --argjson declared "$declared" \
    --argjson available "$available" \
    --argjson manifest "$manifest" \
    --argjson prefixDeclared "$(jnul "$env_prefix_declared")" \
    --argjson prefixRendered "$(jnul "$env_prefix_rendered")" \
    --argjson peers      "$peers_json" \
    --argjson peerTokFp  "$(jnul "$peer_token_fp")" \
    --argjson bearerKeys "$bearer_keys" \
    --argjson peerMapKey "$(jnul "$peer_map_key")" \
    --argjson peerTokKey "$(jnul "$peer_token_key")" \
    --argjson registry "$SYNC_SERVERS" \
    '($registry | map(select(.name == $name)) | .[0]) as $r | {
       name: $name, domain: $domain, upstream: $upstream,
       imagePinned: $pinned, imageRunning: $running,
       container: $state, health: $health, startedAt: $startedAt,
       envFile: $envFile, composeFile: $compose,
       registered: ($r != null), lastSeen: ($r.lastSeen // null), stale: ($r.stale // false),
       httpStatus: $http, envKeys: $envKeys, env: $env,
       server: $server, thisBox: $thisBox, declared: $declared, available: $available,
       manifest: $manifest,
       envPrefix: (if ($manifest.envPrefix // "") == "" then null else $manifest.envPrefix end),
       envPrefixDeclared: $prefixDeclared,
       envPrefixRendered: $prefixRendered,
       syncTokenFingerprint: $syncFp,
       registrationLog: $regLog,
       peers: $peers,
       peerTokenFingerprint: $peerTokFp,
       bearerKeys: $bearerKeys,
       peerMapKey: $peerMapKey,
       peerTokenKey: $peerTokKey
     }'
}

APPS='[]'
if have docker; then
  APPS="$(app_names | sed '/^$/d' | sort -u | while read -r n; do app_json "$n"; done | jq -sc '.')"
else
  note "docker is not installed on this box."
fi

# ==== host-side leftovers ====================================================
# What a box carries from before it was containerised.
#
# This repo assumes it owns 80, 443 and each app's loopback port, and a Caddy or an
# Amber installed straight onto the host owns them first. install.sh refuses in that
# situation — correctly — but a refusal several minutes into a run is a poor way to
# learn something that was knowable at a glance. Reported here so it can be said up
# front instead.

port_holder() {  # port_holder PORT -> the process holding it, or ""
  ss -lntp 2>/dev/null | awk -v p=":$1" '$4 ~ p" *$" {print $NF}' | head -n1 || true
}

# Active or enabled only. `list-unit-files` also lists units that are installed and
# disabled, which is what a MIGRATED box looks like — reporting those kept the
# migration card on screen forever, describing work that was already done.
HOST_UNITS='[]'
if have systemctl; then
  HOST_UNITS="$(for _u in amber caddy sync-store; do
      if systemctl is-active --quiet "$_u" 2>/dev/null || systemctl is-enabled --quiet "$_u" 2>/dev/null; then
        echo "$_u"
      fi
    done | jq -Rn '[inputs]' 2>/dev/null || echo '[]')"
fi

CADDY_CONTAINER=false
if [ "$(container_state caddy)" = "running" ]; then CADDY_CONTAINER=true; fi

HOST_SERVICES="$(jq -n \
  --argjson port80  "$(jnul "$(port_holder 80)")" \
  --argjson port443 "$(jnul "$(port_holder 443)")" \
  --argjson caddyContainer "$CADDY_CONTAINER" \
  --argjson units "$HOST_UNITS" \
  '{port80: $port80, port443: $port443, caddyContainer: $caddyContainer, units: $units}')"

# ==== the edge ===============================================================

CADDY_STATE="$(container_state caddy)"
CADDY_SITES='[]'
if [ -d "$CADDY_SNIPPETS" ]; then
  CADDY_SITES="$(find "$CADDY_SNIPPETS" -maxdepth 1 -name '*.caddy' -exec basename {} .caddy ';' 2>/dev/null \
                 | sort | jq -Rn '[inputs]' || echo '[]')"
fi

# ==== the deploy journal =====================================================
# Tab-separated: ts, service, from, to, result. Written by update-amber.sh and
# rollback.sh; the newest 20 are what anyone actually reads.

JOURNAL='[]'
if [ -r "$HISTORY" ]; then
  JOURNAL="$(tail -n 20 "$HISTORY" | jq -Rn '[inputs
      | split("\t")
      | select(length >= 5)
      | {ts: .[0], service: .[1], from: .[2], to: .[3], result: .[4]}]
    | reverse' || echo '[]')"
fi

# ==== backups ================================================================

BACKUP_TARGET="$(sget '.backup.target' /var/backups/amber-infra)"
BACKUP_COUNT=0
BACKUP_NEWEST=""
if [ -d "$BACKUP_TARGET" ]; then
  BACKUP_COUNT="$(find "$BACKUP_TARGET" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')"
  BACKUP_NEWEST="$(find "$BACKUP_TARGET" -maxdepth 2 -type f -printf '%T@ %TY-%Tm-%TdT%TH:%TM:%TSZ\n' 2>/dev/null \
                   | sort -rn | head -n1 | cut -d' ' -f2 || true)"
fi

# ==== assemble ===============================================================

DOCKER_VERSION="$(docker --version 2>/dev/null | sed 's/,.*//' || true)"
COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || true)"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

jq -n \
  --arg     repoRoot        "$REPO_ROOT" \
  --argjson commit          "$(jnul "$COMMIT")" \
  --argjson role            "$(jnul "$(sget '.infra.role')")" \
  --argjson primaryDomain   "$(jnul "$(sget '.infra.primary_domain')")" \
  --argjson docker          "$(jnul "$DOCKER_VERSION")" \
  --argjson compose         "$(jnul "$COMPOSE_VERSION")" \
  --argjson secretsReadable "$SECRETS_READABLE" \
  --argjson secretsPresent  "$SECRETS_PRESENT" \
  --arg     secretsPath     "$SECRETS_FILE" \
  --argjson placeholdersGen "$PLACEHOLDERS_GEN" \
  --argjson placeholdersManual "$PLACEHOLDERS_MANUAL" \
  --argjson acmeEmailSet    "$ACME_SET" \
  --argjson hostServices    "$HOST_SERVICES" \
  --arg     serverLabel     "$SERVER_LABEL" \
  --argjson catalogue       "$CATALOGUE" \
  --argjson settings        "$(jq -n \
      --argjson acmeEmail     "$(jnul "$ACME_EMAIL")" \
      --argjson primaryDomain "$(jnul "$(sget '.infra.primary_domain')")" \
      --argjson timezone      "$(jnul "$(sget '.infra.timezone')")" \
      --argjson role          "$(jnul "$(sget '.infra.role')")" \
      '{acmeEmail: $acmeEmail, primaryDomain: $primaryDomain, timezone: $timezone, role: $role}')" \
  --argjson tools           "$(jq -n \
      --argjson git "$(have git && echo true || echo false)" \
      --argjson jq_ "$(have jq && echo true || echo false)" \
      --argjson yq_ "$(have yq && echo true || echo false)" \
      --argjson docker "$(have docker && echo true || echo false)" \
      '{git: $git, jq: $jq_, yq: $yq_, docker: $docker}')" \
  --argjson apps            "$APPS" \
  --arg     caddyState      "$CADDY_STATE" \
  --arg     caddyHealth     "$(container_health caddy)" \
  --argjson caddySites      "$CADDY_SITES" \
  --argjson syncUrl         "$(jnul "$SYNC_URL")" \
  --argjson syncReachable   "$SYNC_REACHABLE" \
  --argjson syncServers     "$SYNC_SERVERS" \
  --arg     syncState       "$SYNC_STATE" \
  --argjson syncDetail      "$(jnul "$SYNC_DETAIL")" \
  --argjson syncStartedAt   "$(jnul "$SYNC_STARTED_AT")" \
  --argjson syncPinned      "$(jnul "${SYNC_IMAGE_DEPLOYED:-$SYNC_IMAGE_PINNED}")" \
  --argjson syncDeclared    "$(jnul "$SYNC_IMAGE_PINNED")" \
  --argjson syncRunning     "$(jnul "$SYNC_IMAGE_RUNNING")" \
  --argjson syncKeysOk      "$SYNC_KEYS_READABLE" \
  --argjson syncKeysRunning "$SYNC_KEYS_RUNNING" \
  --argjson syncKeysDeclared "$SYNC_KEYS_DECLARED" \
  --argjson publicIp        "$(jnul "$PUBLIC_IP")" \
  --argjson dnsRecords      "$DNS_RECORDS" \
  --argjson history         "$JOURNAL" \
  --arg     backupTarget    "$BACKUP_TARGET" \
  --argjson backupCount     "${BACKUP_COUNT:-0}" \
  --argjson backupNewest    "$(jnul "$BACKUP_NEWEST")" \
  --argjson warnings        "$WARNINGS" \
  '{
     installed: true,
     schema: 12,
     repoRoot: $repoRoot, commit: $commit, role: $role, primaryDomain: $primaryDomain,
     docker: $docker, compose: $compose,
     tools: $tools,
     secrets: {
       present: $secretsPresent, readable: $secretsReadable, path: $secretsPath,
       acmeEmailSet: $acmeEmailSet,
       placeholders: { generatable: $placeholdersGen, manual: $placeholdersManual }
     },
     settings: $settings,
     hostServices: $hostServices,
     serverLabel: $serverLabel,
     catalogue: $catalogue,
     secretsReadable: $secretsReadable,
     apps: $apps,
     caddy: { running: ($caddyState == "running"), health: $caddyHealth, sites: $caddySites },
     syncStore: { url: $syncUrl, reachable: $syncReachable, servers: $syncServers,
                  containerState: $syncState, detail: $syncDetail,
                  startedAt: $syncStartedAt,
                  imagePinned: $syncPinned, imageDeclared: $syncDeclared,
                  imageRunning: $syncRunning,
                  keys: { readable: $syncKeysOk,
                          running: $syncKeysRunning, declared: $syncKeysDeclared } },
     dns: { publicIp: $publicIp, records: $dnsRecords },
     history: $history,
     backups: { target: $backupTarget, count: $backupCount, newest: $backupNewest },
     warnings: $warnings
   }'
