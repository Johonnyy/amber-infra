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
        SYNC_SERVERS="$(jq -c '(.servers // .) | map({
            name: .name,
            baseUrl: (.base_url // ""),
            lastSeen: (.last_seen // null),
            stale: (.stale // false)
          })' "$SERVERS_BODY" 2>/dev/null || echo '[]')"
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
      secret:     ((.secret // false) or (.name | test("(_KEY|_KEYS|_TOKEN|_SECRET|_PASSWORD|_PASS)$")))
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
  local manifest env_prefix_declared env_prefix_rendered
  manifest="$(manifest_json "$name")"
  env_prefix_declared="$(sget ".apps.\"$name\".env_prefix")"
  env_prefix_declared="${env_prefix_declared%_}"
  env_prefix_rendered=""
  if [ -r "$env_file" ]; then
    env_prefix_rendered="$(grep -oE '^[A-Z][A-Z0-9_]*_SYNC_STORE_URL=' "$env_file" 2>/dev/null \
      | head -n1 | sed 's/_SYNC_STORE_URL=$//' || true)"
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
    --argjson registry "$SYNC_SERVERS" \
    '($registry | map(select(.name == $name)) | .[0]) as $r | {
       name: $name, domain: $domain, upstream: $upstream,
       imagePinned: $pinned, imageRunning: $running,
       container: $state, health: $health,
       envFile: $envFile, composeFile: $compose,
       registered: ($r != null), lastSeen: ($r.lastSeen // null), stale: ($r.stale // false),
       httpStatus: $http, envKeys: $envKeys, env: $env,
       server: $server, thisBox: $thisBox, declared: $declared, available: $available,
       manifest: $manifest,
       envPrefix: (if ($manifest.envPrefix // "") == "" then null else $manifest.envPrefix end),
       envPrefixDeclared: $prefixDeclared,
       envPrefixRendered: $prefixRendered
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
  --argjson publicIp        "$(jnul "$PUBLIC_IP")" \
  --argjson dnsRecords      "$DNS_RECORDS" \
  --argjson history         "$JOURNAL" \
  --arg     backupTarget    "$BACKUP_TARGET" \
  --argjson backupCount     "${BACKUP_COUNT:-0}" \
  --argjson backupNewest    "$(jnul "$BACKUP_NEWEST")" \
  --argjson warnings        "$WARNINGS" \
  '{
     installed: true,
     schema: 9,
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
                  containerState: $syncState, detail: $syncDetail },
     dns: { publicIp: $publicIp, records: $dnsRecords },
     history: $history,
     backups: { target: $backupTarget, count: $backupCount, newest: $backupNewest },
     warnings: $warnings
   }'
