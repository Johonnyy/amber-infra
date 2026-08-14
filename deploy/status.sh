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

# ==== secrets ================================================================
# Deliberately not install/lib/secrets.sh: every read there dies on a missing or
# unreadable file. That is the correct choice for an installer and the wrong one for
# a status command, which must still describe the other half of the box.

SECRETS_READABLE=false
if [ -r "$SECRETS_FILE" ] && have yq; then
  SECRETS_READABLE=true
elif [ -f "$SECRETS_FILE" ]; then
  note "secrets.yaml exists but is not readable as this user — domains, pinned images and env key names are unavailable. Re-run with sudo for the full picture."
else
  note "no secrets file at $SECRETS_FILE — this box has not been through install.sh."
fi

sget() {  # sget YQ_PATH [default] — "" rather than a fatal error when unavailable
  local path="$1" default="${2:-}" value
  if [ "$SECRETS_READABLE" != "true" ]; then echo "$default"; return 0; fi
  value="$(yq -r "$path" "$SECRETS_FILE" 2>/dev/null || true)"
  if [ "$value" = "null" ]; then value=""; fi
  echo "${value:-$default}"
}

http_status() {  # http_status URL -> the code, or "" when nothing answered
  curl -fsS -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null || true
}

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
    --argjson registry "$SYNC_SERVERS" \
    '($registry | map(select(.name == $name)) | .[0]) as $r | {
       name: $name, domain: $domain, upstream: $upstream,
       imagePinned: $pinned, imageRunning: $running,
       container: $state, health: $health,
       envFile: $envFile, composeFile: $compose,
       registered: ($r != null), lastSeen: ($r.lastSeen // null), stale: ($r.stale // false),
       httpStatus: $http, envKeys: $envKeys
     }'
}

APPS='[]'
if have docker; then
  APPS="$(app_names | sed '/^$/d' | sort -u | while read -r n; do app_json "$n"; done | jq -sc '.')"
else
  note "docker is not installed on this box."
fi

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
     repoRoot: $repoRoot, commit: $commit, role: $role, primaryDomain: $primaryDomain,
     docker: $docker, compose: $compose, secretsReadable: $secretsReadable,
     apps: $apps,
     caddy: { running: ($caddyState == "running"), health: $caddyHealth, sites: $caddySites },
     syncStore: { url: $syncUrl, reachable: $syncReachable, servers: $syncServers },
     history: $history,
     backups: { target: $backupTarget, count: $backupCount, newest: $backupNewest },
     warnings: $warnings
   }'
