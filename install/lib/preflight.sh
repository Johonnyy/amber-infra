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

# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# preflight_ports needs container_state to tell our containerised edge apart from a
# Caddy installed on the host — both are just "caddy" in ss output.
# shellcheck source=docker.sh
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

     Check, in this order:
       1. https://github.com/<owner>/<repo>/actions  — did the release run at all?
          The workflow must exist ON the tagged commit; Actions runs the file as it
          is at the pushed ref, so a tag older than the workflow triggers nothing.
       2. https://github.com/<owner>?tab=packages     — is the package there?
       3. If it is there, is it PUBLIC? Packages default to private, and this box
          pulls unauthenticated. Either make it public, or 'docker login ghcr.io'.

     For sync-store specifically there is a third option: its source is in this
     checkout, so the image can be built here instead of pulled —
         docker build -t $image /opt/amber-infra/sync-store
     A locally built image satisfies this check. It also exists only on this box,
     which is fine for one server and wrong for two."
}

public_ip() {
  # Two providers, because a single one being down should not turn "your DNS is
  # wrong" into "checks skipped".
  local ip
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  printf '%s' "$ip"
}

preflight_dns_all() {  # preflight_dns_all DOMAIN...
  # Every hostname this box is about to serve, checked together and BEFORE Caddy is
  # touched.
  #
  # This refuses rather than warns, which is a change: a wrong A record used to be a
  # warning on the grounds that a proxy or split-horizon DNS can legitimately look
  # like one. That was the wrong trade. Caddy asks for a certificate the moment a site
  # block appears, Let's Encrypt rate-limits failures per domain, and the cost of
  # being wrong is not a failed install — it is an hour of not being able to retry.
  # `--skip-dns-check` is there for the setups that really are proxied.
  #
  # All of them are checked before any of them fails, so one round of fixing DNS is
  # enough. Dying on the first would have you find the second twenty minutes later.
  local public domain resolved addresses failed=0 total=0

  step "Checking DNS for every hostname this box will serve"
  public="$(public_ip)"
  if [ -z "$public" ]; then
    warn "could not determine this box's public IP — records can be checked for
     existence but not for pointing here."
  else
    ok "this box is $public"
  fi

  for domain in "$@"; do
    [ -n "$domain" ] || continue
    total=$((total + 1))

    addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [ -z "$addresses" ]; then
      warn "$domain does not resolve at all"
      failed=$((failed + 1))
      continue
    fi

    resolved="$(printf '%s' "$addresses" | tr '\n' ' ' | sed 's/ $//')"
    if [ -z "$public" ]; then
      ok "$domain resolves to $resolved (not verified against this box)"
    # Any address matching is a pass: a name with round-robin records is pointing
    # here even when the first answer is not this box.
    elif printf '%s\n' "$addresses" | grep -qx "$public"; then
      ok "$domain -> $resolved"
    else
      warn "$domain -> $resolved, but this box is $public"
      failed=$((failed + 1))
    fi
  done

  [ "$failed" -eq 0 ] && return 0

  if [ "${SKIP_DNS_CHECK:-0}" = "1" ]; then
    warn "$failed of $total record(s) do not point here — continuing because
     --skip-dns-check was given. ACME will fail for those names."
    return 0
  fi

  die "$failed of $total hostname(s) do not point at this box.

     Fix the A record(s) above to $public and re-run. Nothing has been changed.

     Caddy requests a certificate as soon as a site block appears, and Let's Encrypt
     rate-limits failures per domain — so installing now does not cost one failed
     attempt, it costs an hour of not being able to try again.

     If this is genuinely fronted by a proxy or split-horizon DNS, re-run with
     --skip-dns-check."
}
