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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/install/lib/common.sh"
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
  GEN_PATHS="$(printf '%s' "$SECRETS_JSON" | jq -c '
      [paths(type == "string" and test("CHANGEME")) as $p
       | select((getpath($p) | test("CHANGEME-openssl-rand-hex"))
                or ($p[-1] | tostring | test("_KEYS$")))
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

SYNC_REACHABLE=false
SYNC_SERVERS='[]'
if [ -n "$SYNC_TOKEN" ]; then
  SYNC_BASE="$SYNC_LOCAL"
  if ! curl -fsS -o /dev/null -m 3 "$SYNC_LOCAL/health" 2>/dev/null; then
    SYNC_BASE="$SYNC_URL"
  fi
  if RAW="$(curl -fsS -m 6 -H "Authorization: Bearer $SYNC_TOKEN" "$SYNC_BASE/servers" 2>/dev/null)"; then
    SYNC_REACHABLE=true
    # The store answers either {"servers":[…]} or a bare array. Accept both, exactly
    # as agent-mcp-py's PeerRegistry.refresh does.
    SYNC_SERVERS="$(printf '%s' "$RAW" | jq -c '(.servers // .) | map({
        name: .name,
        baseUrl: (.base_url // ""),
        lastSeen: (.last_seen // null),
        stale: (.stale // false)
      })' 2>/dev/null || echo '[]')"
  else
    note "the sync-store did not answer at $SYNC_BASE/servers — peer registration state is unknown."
  fi
elif [ "$SECRETS_READABLE" = "true" ]; then
  note "no sync-store token for 'amber' in secrets.yaml — the registry cannot be queried."
fi

# ==== apps ===================================================================
# The union of what secrets.yaml declares and what is actually deployed under
# /etc/amber-infra, so an app stood up by hand still appears rather than being
# quietly absent from a screen that claims to list everything.

app_names() {
  if [ "$SECRETS_READABLE" = "true" ]; then
    yq -r '.apps // {} | keys | .[]' "$SECRETS_FILE" 2>/dev/null || true
  fi
  local dir
  for dir in "$ETC"/*/; do
    [ -d "$dir" ] || continue
    [ -e "${dir}docker-compose.prod.yml" ] || continue
    basename "$dir"
  done
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
app_env_json() {  # app_env_json NAME
  if [ "$SECRETS_READABLE" != "true" ]; then echo '[]'; return 0; fi
  yq -o=json ".apps.\"$1\".env // {}" "$SECRETS_FILE" 2>/dev/null | jq -c '
    def issecret: test("(_KEY|_KEYS|_TOKEN|_SECRET|_PASSWORD|_PASS)$");
    # install.sh writes these into the rendered .env AFTER secrets_render_env, so
    # whatever secrets.yaml holds for them is overwritten on every install. Flagging
    # them stops a setup screen listing a derived value as something a human has to
    # go and find — see install/install.sh, "Wiring $APP into the sync-store".
    def isderived:
      test("(_PUBLIC_URL|_SYNC_STORE_URL|_SYNC_STORE_TOKEN)$") or . == "AMBER_UPDATE_COMMAND";
    to_entries | map({
      name: .key,
      secret: (.key | issecret),
      derived: (.key | isderived),
      placeholder: (.value | tostring | test("CHANGEME")),
      set: ((.value | tostring | length) > 0),
      value: (if (.key | issecret) then null else (.value | tostring) end)
    })' 2>/dev/null || echo '[]'
}

app_json() {  # app_json NAME
  local name="$1" dir="$ETC/$1"
  local compose pinned running state health domain upstream http env_file env_keys

  compose="$(find "$dir" -maxdepth 1 -name 'docker-compose*.yml' 2>/dev/null | sort | head -n1 || true)"
  pinned=""
  if [ -n "$compose" ]; then pinned="$(image_of "$compose")"; fi
  if [ -z "$pinned" ]; then pinned="$(sget ".apps.\"$name\".image")"; fi

  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
  running="$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)"
  health="$(container_health "$name")"

  domain="$(sget ".apps.\"$name\".domain")"
  upstream="$(sget ".apps.\"$name\".upstream")"

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
    --argjson env      "$(app_env_json "$name")" \
    --argjson registry "$SYNC_SERVERS" \
    '($registry | map(select(.name == $name)) | .[0]) as $r | {
       name: $name, domain: $domain, upstream: $upstream,
       imagePinned: $pinned, imageRunning: $running,
       container: $state, health: $health,
       envFile: $envFile, composeFile: $compose,
       registered: ($r != null), lastSeen: ($r.lastSeen // null), stale: ($r.stale // false),
       httpStatus: $http, envKeys: $envKeys, env: $env
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

HOST_UNITS='[]'
if have systemctl; then
  HOST_UNITS="$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | sed 's/\.service$//' \
    | grep -xE 'amber|caddy|sync-store' | sort -u | jq -Rn '[inputs]' 2>/dev/null || echo '[]')"
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

CADDY_STATE="$(docker inspect -f '{{.State.Status}}' caddy 2>/dev/null || echo missing)"
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
  --argjson history         "$JOURNAL" \
  --arg     backupTarget    "$BACKUP_TARGET" \
  --argjson backupCount     "${BACKUP_COUNT:-0}" \
  --argjson backupNewest    "$(jnul "$BACKUP_NEWEST")" \
  --argjson warnings        "$WARNINGS" \
  '{
     installed: true,
     schema: 4,
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
     secretsReadable: $secretsReadable,
     apps: $apps,
     caddy: { running: ($caddyState == "running"), health: $caddyHealth, sites: $caddySites },
     syncStore: { url: $syncUrl, reachable: $syncReachable, servers: $syncServers },
     history: $history,
     backups: { target: $backupTarget, count: $backupCount, newest: $backupNewest },
     warnings: $warnings
   }'
