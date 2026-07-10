#!/bin/bash
# bootstrap.sh — one-shot entrypoint an agent (or /new-agent) runs once.
#
# Clones (or pulls) the PRIVATE source repo into a stable path under the agent's
# HQ, then runs install.sh from that checkout. After this, the installed
# SessionStart self-update hook keeps the package current with no further manual
# steps.
#
# Auth for the private repo (first available wins; none -> we still install from
# a locally-provided checkout if one exists, else no-op):
#   1. hq-vault deploy token (HQ_PACK_AGENT_DEPLOY_TOKEN) via `hq secrets get`
#   2. GH_TOKEN / GITHUB_TOKEN in the env
#   3. an authenticated `gh`
# The token is used only in-process (env / header), never persisted to git config
# or printed.
#
# Usage:
#   bootstrap.sh                       # resolve HQ root from env/cwd
#   HQ_PACK_AGENT_HQ_ROOT=/path bootstrap.sh
#   HQ_PACK_AGENT_PROVISION=1 bootstrap.sh   # also drop the agent-identity marker
#
# Always exits 0 (advisory-safe); logs to the package debug log.

trap 'exit 0' EXIT

RELEASE_REPO="${HQ_PACK_AGENT_RELEASE_REPO:-indigoai-us/hq-pack-agent}"
AUTH_SECRET_NAME="${HQ_PACK_AGENT_AUTH_SECRET:-HQ_PACK_AGENT_DEPLOY_TOKEN}"

HQ_ROOT="${HQ_PACK_AGENT_HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$HQ_ROOT" ]; then
  d="$(pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -d "$d/.claude" ] && { HQ_ROOT="$d"; break; }
    d="$(dirname "$d")"
  done
fi
[ -n "$HQ_ROOT" ] && [ -d "$HQ_ROOT/.claude" ] || { echo "[bootstrap] no HQ root" >&2; exit 0; }

STATE_DIR="$HQ_ROOT/workspace/.hq-pack-agent"
REPO_DIR="$STATE_DIR/repo"
LOG="$STATE_DIR/debug.log"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
log() {
  local m; m="$(printf '%s' "$*" | sed -E 's/(gh[pousr]_[A-Za-z0-9]{6,}|[A-Za-z0-9_-]{40,})/<redacted>/g')"
  printf '%s [bootstrap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$m" >> "$LOG" 2>/dev/null || true
}

# (optional) provisioning: drop the durable agent-identity marker so is-agent.sh
# recognizes this HQ as an agent's even without env flags.
if [ "${HQ_PACK_AGENT_PROVISION:-}" = "1" ]; then
  cat > "$STATE_DIR/agent-identity.json" <<EOF
{"provisionedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')","slug":"${HQ_AGENT_SLUG:-unknown}","source":"bootstrap"}
EOF
  log "wrote agent-identity marker"
fi

resolve_token() {
  local t=""
  if command -v hq >/dev/null 2>&1; then
    t="$(hq secrets get "$AUTH_SECRET_NAME" 2>/dev/null | tr -d '\r\n')"; [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  [ -n "${GH_TOKEN:-}" ] && { printf '%s' "$GH_TOKEN"; return 0; }
  [ -n "${GITHUB_TOKEN:-}" ] && { printf '%s' "$GITHUB_TOKEN"; return 0; }
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    t="$(gh auth token 2>/dev/null | tr -d '\r\n')"; [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  return 1
}

TOKEN="$(resolve_token)"

if command -v git >/dev/null 2>&1 && [ -n "$TOKEN" ]; then
  AUTH_URL="https://x-access-token:${TOKEN}@github.com/${RELEASE_REPO}.git"
  if [ -d "$REPO_DIR/.git" ]; then
    log "pulling latest into existing checkout"
    git -C "$REPO_DIR" remote set-url origin "$AUTH_URL" >/dev/null 2>&1
    git -C "$REPO_DIR" fetch --tags --force origin >/dev/null 2>&1
    git -C "$REPO_DIR" reset --hard origin/HEAD >/dev/null 2>&1 || true
    git -C "$REPO_DIR" remote set-url origin "https://github.com/${RELEASE_REPO}.git" >/dev/null 2>&1
  else
    log "cloning private repo"
    rm -rf "$REPO_DIR" 2>/dev/null
    git clone --depth 1 "$AUTH_URL" "$REPO_DIR" >/dev/null 2>&1
    [ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" remote set-url origin "https://github.com/${RELEASE_REPO}.git" >/dev/null 2>&1
  fi
else
  log "no git/auth available; will install from an existing checkout if present"
fi

# Choose install source: the fetched checkout, else a checkout already present,
# else the dir this bootstrap was run from (covers a manual local install).
SELF_SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
INSTALL_SRC=""
for cand in "$REPO_DIR" "$SELF_SRC"; do
  [ -f "$cand/install/install.sh" ] && { INSTALL_SRC="$cand"; break; }
done
[ -n "$INSTALL_SRC" ] || { log "no install source found; no-op"; exit 0; }

log "running install.sh from $INSTALL_SRC"
HQ_PACK_AGENT_HQ_ROOT="$HQ_ROOT" bash "$INSTALL_SRC/install/install.sh" >/dev/null 2>&1 \
  && log "bootstrap install OK" \
  || log "bootstrap install returned non-zero"

exit 0
