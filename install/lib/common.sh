#!/usr/bin/env bash
#
# Shared shell plumbing for every script in this repo.
#
# The output palette is copied verbatim from amber_v2/deploy/update.sh so the whole
# ecosystem speaks with one voice — a step in install.sh should look exactly like a
# step in Amber's own updater, because to whoever is watching the terminal at 2am it
# is the same operation.
#
# Source it, don't execute it:
#   . "$(dirname "$0")/lib/common.sh"

# Guard against double-sourcing (install.sh sources several libs that each source
# this one).
[ -n "${_AMBER_INFRA_COMMON:-}" ] && return 0
_AMBER_INFRA_COMMON=1

set -euo pipefail

# --- pretty output -----------------------------------------------------------
c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
step() { echo; echo "${c_blue}==>${c_off} $*"; }
ok()   { echo "${c_green} ok${c_off} $*"; }
warn() { echo "${c_yellow} ! ${c_off} $*"; }
die()  { echo "${c_red}error:${c_off} $*" >&2; exit 1; }

# --- dry run -----------------------------------------------------------------
# DRY_RUN=1 makes every mutating call a printed intention. Built in from the start
# deliberately: a deploy script you cannot rehearse is one you test in production.
DRY_RUN="${DRY_RUN:-0}"

run() {  # run CMD ... — the single choke point for anything that changes the box
  if [ "$DRY_RUN" = "1" ]; then
    echo "   ${c_yellow}dry-run${c_off} $*"
    return 0
  fi
  "$@"
}

dry() { [ "$DRY_RUN" = "1" ]; }

# --- prompts -----------------------------------------------------------------
# Both read from /dev/tty, not stdin, so they still work when the script itself was
# piped in (curl … | sudo bash).
ask() {  # ask "Prompt" "default" -> echoes the answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " reply </dev/tty || reply=""
  else
    read -rp "$prompt: " reply </dev/tty || reply=""
  fi
  echo "${reply:-$default}"
}

ask_secret() {  # ask_secret "Prompt" -> echoes the answer, input hidden
  local prompt="$1" reply
  read -rsp "$prompt: " reply </dev/tty; echo >&2
  echo "$reply"
}

confirm() {  # confirm "Question" -> 0 if yes
  local reply
  reply="$(ask "$1 [y/N]" "n")"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# --- guards ------------------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || die "run as root (try: sudo bash $0)"; }

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() { have "$1" || die "missing required command: $1"; }

# --- retries and waits -------------------------------------------------------
retry() {  # retry N CMD ... — linear backoff, 2s per attempt
  local attempts="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    n=$((n + 1))
    sleep 2
  done
  return 0
}

wait_for_http() {  # wait_for_http URL TIMEOUT_S — 0 when it answers 2xx/3xx
  local url="$1" timeout="${2:-60}" waited=0
  dry && { echo "   ${c_yellow}dry-run${c_off} would wait for $url"; return 0; }
  while [ "$waited" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# --- misc --------------------------------------------------------------------
gen_token() { openssl rand -hex 32; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

#: Repo root, however the caller invoked us. Every path in this repo is derived
#: from this rather than from $PWD, so `bash install/install.sh` and
#: `bash /opt/amber-infra/install/install.sh` behave identically.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
