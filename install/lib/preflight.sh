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
# preflight_ports needs container_state to tell our containerised edge apart from a
# Caddy installed on the host — both are just "caddy" in ss output.
. "$(dirname "${BASH_SOURCE[0]}")/docker.sh"

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
  # Only *our* Caddy may hold 80/443. Anything else there means an nginx or an Apache
  # nobody remembered, and Caddy would fail to bind with a much less obvious error.
  #
  # The process name alone cannot settle it. The edge runs with `network_mode: host`,
  # so a containerised Caddy and one installed straight onto the box are both just
  # `caddy` in `ss` output — and accepting the name was how a host Caddy sailed
  # through this check and then blocked the container from ever binding. The question
  # that actually distinguishes them is whether our *container* is running.
  local port holder
  for port in 80 443; do
    holder="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p" *$" {print $NF}' | head -n1 || true)"
    if [ -z "$holder" ]; then
      ok "port $port free"
      continue
    fi
    case "$holder" in
      *caddy*|*docker*)
        if [ "$(container_state caddy)" = "running" ]; then
          ok "port $port held by the containerised edge ($holder)"
        else
          die "port $port is held by $holder, but there is no running 'caddy' container.
     That is a Caddy installed directly on this box. The edge here runs with
     network_mode: host and cannot bind a port the host copy already owns.

     Stop and disable the host one first:
         systemctl disable --now caddy

     Its config is /etc/caddy/Caddyfile, which this repo overwrites — copy anything
     you still need out of it before you do."
        fi
        ;;
      *) die "port $port is already held by $holder — stop it before installing the Caddy edge" ;;
    esac
  done
}

preflight_upstream() {  # preflight_upstream APP HOST:PORT
  # The app's own loopback port, checked for the same reason as 80/443 and missed for
  # longer: this repo containerises services that already exist on the box as systemd
  # units. Amber is the case that matters — `amber.service` binds 127.0.0.1:8000, and
  # the container wants the same port. Without this, `docker compose up` fails with a
  # bind error several minutes into an install that has already rewritten the firewall
  # and the TLS edge.
  local app="$1" port holder
  port="${2##*:}"
  case "$port" in ''|*[!0-9]*) return 0 ;; esac

  holder="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p" *$" {print $NF}' | head -n1 || true)"
  if [ -z "$holder" ]; then
    ok "upstream port $port free"
    return 0
  fi
  if [ "$(container_state "$app")" = "running" ]; then
    ok "upstream port $port held by the $app container"
    return 0
  fi

  die "upstream port $port is held by $holder, and the '$app' container is not running.
     Something else on this box is already serving there — most often an earlier,
     non-containerised deployment of the same app.

     For Amber that is the systemd unit from amber_v2/deploy. Move her database onto
     the container volume FIRST, because the container will not find it otherwise:
         sudo bash $REPO_ROOT/deploy/migrate-amber-db.sh --dry-run
         sudo bash $REPO_ROOT/deploy/migrate-amber-db.sh
     That script stops the unit and leaves it installed, which is your rollback
     (systemctl start amber). Then re-run this install."
}

preflight_image() {  # preflight_image IMAGE
  # Can this box actually get the image it is pinned to?
  #
  # `compose_up` finds out the hard way, four steps and several minutes in, after the
  # firewall and the TLS edge have already been rewritten. And a dry run cannot find
  # out at all: `run docker compose pull` prints an intention. So this asks the
  # registry directly, which is the one part of a deploy that a rehearsal can check
  # for real.
  #
  # A published image and a *readable* one are the same question here — GHCR packages
  # are private by default, and an unauthenticated pull of a private package fails
  # exactly like a pull of one that was never pushed. Both are "this box cannot get
  # it", which is what the message says.
  local image="$1"
  [ -n "$image" ] || return 0

  # Already on disk is enough: `pull` on an exact tag is a no-op when it is present,
  # which is also what makes a rollback work offline.
  if docker image inspect "$image" >/dev/null 2>&1; then
    ok "image present locally: $image"
    return 0
  fi
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    ok "image is pullable: $image"
    return 0
  fi

  die "this box cannot pull $image.

     Either the tag was never published, or the package is private and this box is
     not logged in. GHCR packages default to PRIVATE, which fails identically to one
     that does not exist.

     Images are published by a version tag, not by pushing to main:
         git tag v0.1.0 && git push origin v0.1.0
     and the workflow has to already exist ON the commit being tagged — Actions runs
     the workflow file as it is at the pushed ref, so a tag placed before the workflow
     was committed triggers nothing at all.

     Check: https://github.com/<owner>?tab=packages
     If it is there but private, make it public, or run 'docker login ghcr.io' here."
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
    warn "$domain resolves to $resolved but this box's public IP is $public.

     Unless a proxy or split-horizon DNS explains that — which is the only reason this
     is a warning and not a refusal — the A record is simply wrong, and ACME will fail
     every time Caddy retries. Let's Encrypt rate-limits failures per domain, so the
     cost of continuing is not one failed install, it is an hour of not being able to
     try again.

     Fix the A record to point at $public, then re-run. Continuing anyway."
  else
    ok "$domain resolves to $resolved"
  fi
}
