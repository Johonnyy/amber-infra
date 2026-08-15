#!/usr/bin/env bash
#
# Deploying the sync-store and wiring an app into it.
#
# The rule here, and it is the one worth arguing about: THIS SCRIPT NEVER POSTS A
# DESCRIPTOR ON AN APP'S BEHALF. Registration is agent_mcp's job on startup. Doing
# it from bash would produce a registry entry that outlives the app being broken —
# a peer that every agent believes in and nothing answers for. install.sh's job is
# to make registration possible (public URL, store URL, token) and then to VERIFY
# that the app did it itself.
#
# The one exception is sync_store_post_descriptor, for a non-Python app that ships a
# descriptor.json because it has no agent-mcp-py to do this for it. That is the
# exception, not the path.

# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

[ -n "${_AMBER_INFRA_SYNC_STORE:-}" ] && return 0
_AMBER_INFRA_SYNC_STORE=1

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=docker.sh
. "$(dirname "${BASH_SOURCE[0]}")/docker.sh"
# shellcheck source=secrets.sh
. "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

SYNC_STORE_DIR="${SYNC_STORE_DIR:-/etc/amber-infra/sync-store}"

sync_store_local_url() {
  echo "http://127.0.0.1:$(secrets_get '.sync_store.port' 8081)"
}

sync_store_base_url() {
  # Loopback when the store runs on this box (Server A), the public URL otherwise
  # (Server B, where the same code has to reach it through Caddy). Resolved per
  # call rather than cached, because ensure_sync_store may have just made the
  # loopback answer.
  if curl -fsS -o /dev/null --max-time 3 "$(sync_store_local_url)/health" 2>/dev/null; then
    sync_store_local_url
  else
    secrets_require '.sync_store.url'
  fi
}

sync_store_up() {
  [ "$(container_health sync-store)" = "healthy" ] && return 0
  curl -fsS -o /dev/null --max-time 3 "$(sync_store_base_url)/health" 2>/dev/null
}

ensure_sync_store() {
  step "Ensuring the sync-store is running"

  local image port keys
  image="$(secrets_require '.sync_store.image')"
  port="$(secrets_get '.sync_store.port' 8081)"
  keys="$(secrets_sync_store_keys)"
  [ -n "$keys" ] || die "$SECRETS_FILE: sync_store.keys is empty — the store would reject every request"
  case "$keys" in *CHANGEME*) die "$SECRETS_FILE: sync_store.keys still holds a CHANGEME placeholder" ;; esac

  # Already running is not the same as already correct.
  #
  # This used to return here unconditionally, which meant a store started before an
  # app existed never learned that app's key — `SYNC_STORE_KEYS` is read once, at
  # startup. Installing a second app therefore produced a registration 401 forever,
  # and the app itself looked perfectly healthy while it happened.
  #
  # So reconcile instead: compare the rendered key list against secrets.yaml and
  # restart ONLY when it actually changed. Restarting a healthy registry on every
  # install would be its own small outage, repeated.
  if sync_store_up; then
    local current=""
    [ -f "$SYNC_STORE_DIR/sync-store.env" ] \
      && current="$(env_get "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_KEYS || true)"
    if [ "$current" = "$keys" ]; then
      ok "sync-store already answering on $(sync_store_local_url)/health"
      return 0
    fi
    step "The sync-store key list has changed — reloading it"
    env_set "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_KEYS "$keys"
    env_protect "$SYNC_STORE_DIR/sync-store.env"
    # `--force-recreate` rather than trusting compose to notice. Whether a changed
    # env_file alone counts as a config change has varied between compose versions,
    # and "the container is up but running the old key list" is precisely the silent
    # state this whole function is here to end. No pull: the image has not changed.
    compose "$SYNC_STORE_DIR" up -d --force-recreate
    wait_healthy sync-store 90 || die "sync-store did not come back after reloading its keys — docker logs sync-store"
    ok "sync-store reloaded with $(printf '%s' "$keys" | tr ',' '\n' | grep -c .) key(s)"
    return 0
  fi

  run mkdir -p "$SYNC_STORE_DIR"
  run install -m 644 "$REPO_ROOT/sync-store/docker-compose.prod.yml" \
      "$SYNC_STORE_DIR/docker-compose.prod.yml"
  if ! dry; then
    sed -i -E "s|^(\s*image:).*|\1 $image|" "$SYNC_STORE_DIR/docker-compose.prod.yml"
    sed -i -E "s|127\.0\.0\.1:[0-9]+:8080|127.0.0.1:$port:8080|" \
        "$SYNC_STORE_DIR/docker-compose.prod.yml"
  fi

  run install -m 600 -o root -g root /dev/null "$SYNC_STORE_DIR/sync-store.env"
  env_set "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_DB_PATH /data/sync-store.db
  env_set "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_KEYS "$keys"
  env_set "$SYNC_STORE_DIR/sync-store.env" SYNC_STORE_ALLOW_ANONYMOUS false
  env_protect "$SYNC_STORE_DIR/sync-store.env"

  compose_up "$SYNC_STORE_DIR"
  wait_healthy sync-store 90 || die "sync-store did not come up — docker logs sync-store"
  ok "sync-store deployed"
}

sync_store_token_for() {  # sync_store_token_for APP -> the bearer token, generating one if absent
  local app="$1" token index
  token="$(yq -r ".sync_store.keys[] | select(.name == \"$app\") | .token" "$SECRETS_FILE" 2>/dev/null | head -n1)"
  case "$token" in
    ''|null|*CHANGEME*)
      token="$(gen_token)"
      index="$(yq -r ".sync_store.keys | length" "$SECRETS_FILE")"
      warn "no usable sync-store token for '$app' — generating one and writing it back to $SECRETS_FILE"
      secrets_set ".sync_store.keys[$index].name" "$app"
      secrets_set ".sync_store.keys[$index].token" "$token"
      echo "     token for $app: $token" >&2
      echo "     (printed once; it lives in $SECRETS_FILE from now on)" >&2
      ;;
  esac
  echo "$token"
}

sync_store_admin_token() {  # -> amber's bearer, or "" — NEVER mints one
  # The read-only twin of sync_store_token_for, for the callers that only want to
  # *query* the registry: install.sh's verification step and uninstall.sh's
  # deregistration.
  #
  # Using the minting version there was a quiet trap. Both run after the store has
  # already been rendered and started, so on a box with no `amber` entry they invented
  # one the running store had never heard of — and then used it. The verification
  # then 401s and reports "'bloom' has not appeared in the registry", blaming the app
  # for what is the checker's own credential being unknown. Worse, uninstall.sh wrote
  # a brand-new key into secrets.yaml as a side effect of REMOVING something.
  local token
  token="$(yq -r '.sync_store.keys[]? | select(.name == "amber") | .token' "$SECRETS_FILE" 2>/dev/null | head -n1 || true)"
  case "$token" in null|*CHANGEME*) token="" ;; esac
  echo "$token"
}

sync_store_wait_for_registration() {  # ... NAME TIMEOUT_S ADMIN_TOKEN
  local name="$1" timeout="${2:-60}" token="$3" waited=0 url
  url="$(sync_store_base_url)/servers"
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would wait for '$name' to appear in the registry"
    return 0
  fi
  step "Waiting for '$name' to register itself with the sync-store"
  while [ "$waited" -lt "$timeout" ]; do
    if curl -fsS --max-time 5 -H "Authorization: Bearer $token" "$url" 2>/dev/null \
       | grep -q "\"name\":\"$name\""; then
      ok "'$name' is registered and discoverable"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done

  # register() swallows every failure by contract, so the store has no idea why
  # this did not happen and neither do we. The app's own log is the only place the
  # reason exists — say so, with the command.
  warn "'$name' has not appeared in the registry after ${timeout}s.

     agent_mcp's register() logs and swallows every failure, so the reason is in
     the APP's log, not the store's:
         docker logs $name --tail 100 | grep -i 'sync store'
     Most common causes:
       * *_PUBLIC_URL unset  — register() refuses before any HTTP is attempted
       * *_SYNC_STORE_TOKEN does not match an entry in sync_store.keys
       * the app has not finished starting (registration happens on startup)"
  return 1
}

sync_store_post_descriptor() {  # sync_store_post_descriptor FILE TOKEN
  # For a non-Python app with no agent-mcp-py to register for it. The exception.
  local file="$1" token="$2"
  [ -f "$file" ] || die "no descriptor at $file"
  warn "registering $file by hand — this app has no agent-mcp-py to do it on startup,
     which also means nothing will re-register it if the store is ever reset"
  run curl -fsS -X POST "$(sync_store_base_url)/servers" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data @"$file"
}

sync_store_deregister() {  # sync_store_deregister NAME TOKEN
  local name="$1" token="$2"
  # if/else, not `A && B || C`. With the latter a failing `ok` would also run the
  # warn branch, reporting both outcomes for a single call.
  if run curl -fsS -X DELETE "$(sync_store_base_url)/servers/$name" \
      -H "Authorization: Bearer $token" >/dev/null 2>&1; then
    ok "removed '$name' from the registry"
  else
    warn "could not remove '$name' from the registry (it may not have been there)"
  fi
}
