#!/usr/bin/env bash
#
# The TLS edge: rendering per-app snippets and reloading Caddy safely.
#
# The rule this file exists to enforce: VALIDATE BEFORE RELOAD. `caddy reload` is
# atomic and keeps the old config when the new one is bad, so a failed reload is not
# an outage — but the error arrives as a wall of adapter output with no indication
# which of a dozen snippets caused it. Validating first localises the failure to the
# file we just wrote, and lets us remove it again before anyone is confused.

[ -n "${_AMBER_INFRA_CADDY:-}" ] && return 0
_AMBER_INFRA_CADDY=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
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

  if [ "$(container_health caddy)" = "missing" ]; then
    compose_up "$CADDY_DIR"
  else
    ok "caddy already running"
    caddy_validate && caddy_reload
  fi
}

caddy_add_site() {  # caddy_add_site NAME DOMAIN UPSTREAM
  local name="$1" domain="$2" upstream="$3"
  local target="$CADDY_SNIPPETS/$name.caddy"
  local source="$REPO_ROOT/caddy/snippets/$name.caddy"
  local backup=""

  step "Adding the Caddy site for $name ($domain -> $upstream)"

  [ -f "$target" ] && { backup="$(mktemp)"; cp "$target" "$backup"; }

  if [ -f "$source" ]; then
    # A committed snippet wins over the template: amber.caddy and sync-store.caddy
    # carry per-service decisions (log_skip, the streaming import) that a generic
    # render would flatten.
    run install -m 644 "$source" "$target"
  else
    if dry; then
      echo "   ${c_yellow}dry-run${c_off} would render $target from _template.caddy"
    else
      sed -e "s|{{DOMAIN}}|$domain|g" \
          -e "s|{{APP_NAME}}|$name|g" \
          -e "s|{{UPSTREAM}}|$upstream|g" \
          "$REPO_ROOT/caddy/snippets/_template.caddy" > "$target"
      chmod 644 "$target"
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
