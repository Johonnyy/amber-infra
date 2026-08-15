#!/usr/bin/env bash
#
# The TLS edge: rendering per-app snippets and reloading Caddy safely.
#
# The rule this file exists to enforce: VALIDATE BEFORE RELOAD. `caddy reload` is
# atomic and keeps the old config when the new one is bad, so a failed reload is not
# an outage — but the error arrives as a wall of adapter output with no indication
# which of a dozen snippets caused it. Validating first localises the failure to the
# file we just wrote, and lets us remove it again before anyone is confused.

# shellcheck source-path=SCRIPTDIR
# ^ must appear before any COMMAND to be file-wide. Placed after one (the
#   double-source guard) it binds to the next statement only, and every source
#   after the first goes back to SC1091.

[ -n "${_AMBER_INFRA_CADDY:-}" ] && return 0
_AMBER_INFRA_CADDY=1

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=docker.sh
. "$(dirname "${BASH_SOURCE[0]}")/docker.sh"

CADDY_ETC="${CADDY_ETC:-/etc/caddy}"
CADDY_SNIPPETS="$CADDY_ETC/snippets"
CADDY_DIR="${CADDY_DIR:-/etc/amber-infra/caddy}"

caddy_validate() {
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would validate $CADDY_ETC/Caddyfile"
    return 0
  fi
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

caddy_reload() {
  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would reload caddy"
    return 0
  fi
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

ensure_caddy() {  # ensure_caddy ACME_EMAIL
  local acme_email="$1"
  step "Ensuring the TLS edge is up"

  run mkdir -p "$CADDY_SNIPPETS" /var/log/caddy "$CADDY_DIR"
  run install -m 644 "$REPO_ROOT/caddy/Caddyfile" "$CADDY_ETC/Caddyfile"
  run install -m 644 "$REPO_ROOT/caddy/docker-compose.caddy.yml" \
      "$CADDY_DIR/docker-compose.caddy.yml"
  # ACME_EMAIL reaches the Caddyfile's {$ACME_EMAIL} placeholder through compose's
  # own env file, not the app env files — it belongs to the edge, not to any app.
  run bash -c "printf 'ACME_EMAIL=%s\n' '$acme_email' > '$CADDY_DIR/.env'"
  run chmod 600 "$CADDY_DIR/.env"

  # The condition is "is the container RUNNING", not "does something called caddy
  # exist". Both branches below reach it with `docker exec`, which needs a running
  # container — a stopped one, or an image of the same name, made this take the
  # reload path and fail with a raw daemon error.
  if [ "$(container_state caddy)" = "running" ]; then
    ok "caddy container already running"
    caddy_validate && caddy_reload
  else
    compose_up "$CADDY_DIR"
  fi
}

caddy_add_site() {  # caddy_add_site NAME DOMAIN UPSTREAM
  local name="$1" domain="$2" upstream="$3"
  local target="$CADDY_SNIPPETS/$name.caddy"
  local source="$REPO_ROOT/caddy/snippets/$name.caddy"
  local backup=""

  step "Adding the Caddy site for $name ($domain -> $upstream)"

  [ -f "$target" ] && { backup="$(mktemp)"; cp "$target" "$backup"; }

  # A committed snippet wins over the generic template — amber.caddy and
  # sync-store.caddy carry per-service decisions (log_skip, the streaming import)
  # that a generic render would flatten. But it is still a TEMPLATE: it is rendered
  # with the same substitutions, never copied verbatim.
  #
  # Copying it verbatim is what this used to do, and the snippets carried literal
  # hostnames. So `--domain` was honoured by the preflight and by *_PUBLIC_URL and
  # then silently discarded here: the box served, and asked Let's Encrypt for, the
  # domain that happened to be committed in this repo.
  [ -f "$source" ] || source="$REPO_ROOT/caddy/snippets/_template.caddy"
  [ -f "$source" ] || die "no snippet and no template at $source"

  if dry; then
    echo "   ${c_yellow}dry-run${c_off} would render $target from $(basename "$source") ($domain -> $upstream)"
  else
    sed -e "s|{{DOMAIN}}|$domain|g" \
        -e "s|{{APP_NAME}}|$name|g" \
        -e "s|{{UPSTREAM}}|$upstream|g" \
        "$source" > "$target"
    chmod 644 "$target"
    # A placeholder that survives means a snippet used a spelling this does not
    # substitute — which would reach the adapter as a literal and fail there, several
    # steps later and much less clearly.
    if grep -q '{{' "$target"; then
      rm -f "$target"
      die "$(basename "$source") still contains an unsubstituted {{placeholder}} after rendering.
     Only {{DOMAIN}}, {{APP_NAME}} and {{UPSTREAM}} are supported."
    fi
  fi

  if ! caddy_validate; then
    # Undo before anyone has to guess which snippet broke the adapter.
    if [ -n "$backup" ]; then cp "$backup" "$target"; else rm -f "$target"; fi
    rm -f "${backup:-/nonexistent}"
    die "the new snippet for $name does not validate; it has been removed and Caddy is untouched"
  fi
  rm -f "${backup:-/nonexistent}"

  caddy_reload
  ok "site added"

  # ACME issuance is not instant, and a first-time cert on a fresh domain can take
  # the better part of a minute. Failing here is a warning, not a die: the site is
  # configured correctly and will come up on its own.
  if wait_for_http "https://$domain/health" 120; then
    ok "https://$domain/health is answering"
  else
    warn "https://$domain/health did not answer within 120s.
     Check: docker logs caddy --tail 50   (ACME failures name the domain)
     Most common cause: DNS for $domain does not point at this box yet."
  fi
}

caddy_remove_site() {  # caddy_remove_site NAME
  local name="$1"
  if [ ! -f "$CADDY_SNIPPETS/$name.caddy" ]; then
    ok "no Caddy snippet for $name"
    return 0
  fi
  run rm -f "$CADDY_SNIPPETS/$name.caddy"
  caddy_validate && caddy_reload
  ok "removed the Caddy site for $name"
}
