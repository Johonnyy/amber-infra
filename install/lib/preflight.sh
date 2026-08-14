#!/usr/bin/env bash
#
# Checks that run before anything is changed.
#
# The DNS check is the one that earns its place. Caddy requests certificates over
# ACME as soon as a site block appears, and Let's Encrypt rate-limits failures per
# domain — so installing an app whose DNS does not point here yet does not merely
# fail, it can lock you out of retrying for an hour. Checking first turns that into
# a five-second refusal.

[ -n "${_AMBER_INFRA_PREFLIGHT:-}" ] && return 0
_AMBER_INFRA_PREFLIGHT=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

preflight_system() {
  step "Preflight"
  require_root

  have apt-get || die "this installer is apt-based (Debian/Ubuntu); adapt install/lib for another distro"

  local free_mb
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  [ "${free_mb:-0}" -ge 1024 ] || die "only ${free_mb}MB free on / — need at least 1GB for images and backups"
  ok "disk: ${free_mb}MB free on /"

  if have systemctl && systemctl is-active --quiet systemd-resolved; then
    ok "systemd-resolved active"
  fi
}

preflight_ports() {
  # Only Caddy may hold 80/443. Anything else there means an nginx or an Apache
  # nobody remembered, and Caddy would fail to bind with a much less obvious error.
  local port holder
  for port in 80 443; do
    holder="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p" *$" {print $NF}' | head -n1)"
    if [ -n "$holder" ]; then
      case "$holder" in
        *caddy*|*docker*) ok "port $port held by the edge ($holder)" ;;
        *) die "port $port is already held by $holder — stop it before installing the Caddy edge" ;;
      esac
    else
      ok "port $port free"
    fi
  done
}

preflight_dns() {  # preflight_dns DOMAIN
  local domain="$1" resolved public
  [ -n "$domain" ] || return 0

  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -z "$resolved" ]; then
    die "$domain does not resolve.
     Point an A record at this box BEFORE installing: Caddy requests a certificate
     as soon as the site block appears, and Let's Encrypt rate-limits failures per
     domain — a premature attempt can lock you out of retrying for an hour."
  fi

  public="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$public" ] && [ "$resolved" != "$public" ]; then
    warn "$domain resolves to $resolved but this box's public IP looks like $public.
     ACME will fail unless the domain points here. Continuing anyway — a proxy or
     a split-horizon DNS setup can legitimately look like this."
  else
    ok "$domain resolves to $resolved"
  fi
}
