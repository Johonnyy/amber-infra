#!/usr/bin/env bash
#
# Update Amber. A thin wrapper over deploy/update-app.sh.
#
# Triggered three ways, and the reason this file still exists is that two of them name
# it by path and cannot be changed casually:
#   * by voice — Amber's update_server tool runs AMBER_UPDATE_COMMAND, which is
#     `touch /signals/update-requested`; amber-update.path sees it and starts
#     amber-update.service, which runs THIS script;
#   * by hand — `sudo /opt/amber-infra/deploy/update-amber.sh`;
#   * from Aperture — the Servers tab, with --dry-run first and then for real.
#
# Everything it used to do now lives in update-app.sh, which every other app shares.
# What stays here is the two things that are genuinely Amber's:
#
#   * the signal directory the systemd .path unit watches, and
#   * AMBER_FEATURE_LLM. With the brain off she runs on the canned responder and needs
#     no OpenRouter key, so requiring one would refuse an update to a configuration
#     that works. The manifest cannot express "required unless another key is false",
#     and teaching it to would be a schema for one case — so the exception lives here,
#     next to the flag it is about.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../install/lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"
# shellcheck source=../install/lib/env.sh
. "$REPO_ROOT/install/lib/env.sh"

AMBER_DIR="${AMBER_DIR:-/etc/amber-infra/amber}"
ENV_FILE="$AMBER_DIR/amber.env"

PASS_THROUGH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) PASS_THROUGH+=("--dry-run"); shift ;;
    --to)      PASS_THROUGH+=("--to" "$2"); shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

# AMBER_ rather than AMBER_MCP: this filters which keys `env_reconcile` will add from
# the image's own .env.example, and Amber's keys span AMBER_* — her own, agent_runtime's
# and agent_mcp's — all built from one prefix with `_env_file=None`. See app/config.py.
PASS_THROUGH+=("--env-prefix" "AMBER_")

# The signal directory amber-update.path watches. Exported rather than passed, because
# update-app.sh treats it as an environment override for exactly this case.
export SIGNAL_DIR="${SIGNAL_DIR:-/var/lib/amber-infra/amber/signals}"

LLM="$(env_get "$ENV_FILE" AMBER_FEATURE_LLM 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
if [ "$LLM" = "false" ]; then
  warn "AMBER_FEATURE_LLM=false — not requiring an OpenRouter key for this update"
  PASS_THROUGH+=("--optional" "AMBER_OPENROUTER_API_KEY")
fi

exec bash "$REPO_ROOT/deploy/update-app.sh" amber "${PASS_THROUGH[@]}"
