#!/bin/bash
# do-update.sh — detached background updater for hq-pack-agent.
#
# Invoked (backgrounded, detached) by hooks/agent-pack-update.sh when a newer
# release exists. Runs OUTSIDE session-start latency; its result lands on the
# next session.
#
#   arg1                          target version (informational / log)
#   env HQ_PACK_AGENT_HQ_ROOT     the agent's HQ root
#   env HQ_PACK_AGENT_RELEASE_REPO  owner/repo of the private source
#   env HQ_PACK_AGENT_UPDATE_TOKEN   auth token (env only; never logged/argv)
#
# Guarantees:
#   * Backs up the CURRENT installed package tree to workspace/.hq-pack-agent/prev/
#     before touching anything, so a bad release can't brick updates.
#   * Pulls the new release into the repo checkout, then re-runs install.sh.
#   * If the new install.sh exits non-zero, ROLLS BACK: restores the prev tree and
#     re-runs the OLD install.sh, so the agent keeps the last-good version.
#   * All output is swallowed; progress goes only to the package debug log. The
#     token is never written to disk or argv.
#   * Always exits 0.

trap 'exit 0' EXIT

TARGET_VERSION="${1:-}"
HQ_ROOT="${HQ_PACK_AGENT_HQ_ROOT:-}"
RELEASE_REPO="${HQ_PACK_AGENT_RELEASE_REPO:-indigoai-us/hq-pack-agent}"
TOKEN="${HQ_PACK_AGENT_UPDATE_TOKEN:-}"

[ -n "$HQ_ROOT" ] || exit 0

STATE_DIR="$HQ_ROOT/workspace/.hq-pack-agent"
REPO_DIR="$STATE_DIR/repo"
PREV_DIR="$STATE_DIR/prev"
LOG="$STATE_DIR/debug.log"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

log() {
  local msg; msg="$(printf '%s' "$*" | sed -E 's/(gh[pousr]_[A-Za-z0-9]{6,}|[A-Za-z0-9_-]{40,})/<redacted>/g')"
  printf '%s [do-update] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$msg" >> "$LOG" 2>/dev/null || true
}

# A single flock so two detached updaters never race.
LOCK="$STATE_DIR/update.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" 2>/dev/null || true
  flock -n 9 2>/dev/null || { log "another updater holds the lock; exiting"; exit 0; }
fi

log "starting update -> ${TARGET_VERSION:-unknown} (repo=$RELEASE_REPO)"

[ -n "$TOKEN" ] || { log "no token in env; aborting"; exit 0; }
command -v git >/dev/null 2>&1 || { log "git missing; aborting"; exit 0; }

# Authenticated remote URL kept ONLY in-process (never persisted to git config,
# so the token can't leak via .git/config on disk).
AUTH_URL="https://x-access-token:${TOKEN}@github.com/${RELEASE_REPO}.git"

# --- Back up the current install so we can roll back. ---
CURRENT_VERSION="$(head -1 "$STATE_DIR/installed-version" 2>/dev/null | tr -dc '0-9.')"
rm -rf "$PREV_DIR" 2>/dev/null
if [ -d "$REPO_DIR" ]; then
  cp -a "$REPO_DIR" "$PREV_DIR" 2>/dev/null || { log "backup failed; aborting to stay safe"; exit 0; }
  log "backed up current tree (v${CURRENT_VERSION:-?}) to prev/"
fi

# --- Fetch the new release into REPO_DIR. ---
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" remote set-url origin "$AUTH_URL" >/dev/null 2>&1
  git -C "$REPO_DIR" fetch --tags --force origin >/dev/null 2>&1
  git -C "$REPO_DIR" checkout -f "v${TARGET_VERSION}" >/dev/null 2>&1 \
    || git -C "$REPO_DIR" checkout -f "$TARGET_VERSION" >/dev/null 2>&1 \
    || git -C "$REPO_DIR" reset --hard origin/HEAD >/dev/null 2>&1
  git -C "$REPO_DIR" remote set-url origin "https://github.com/${RELEASE_REPO}.git" >/dev/null 2>&1
else
  rm -rf "$REPO_DIR" 2>/dev/null
  git clone --depth 1 --branch "v${TARGET_VERSION}" "$AUTH_URL" "$REPO_DIR" >/dev/null 2>&1 \
    || git clone --depth 1 "$AUTH_URL" "$REPO_DIR" >/dev/null 2>&1
  # Scrub the token out of the persisted remote immediately.
  [ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" remote set-url origin "https://github.com/${RELEASE_REPO}.git" >/dev/null 2>&1
fi

if [ ! -f "$REPO_DIR/install/install.sh" ]; then
  log "pulled tree has no install/install.sh; rolling back"
  restore_prev=1
else
  log "running new install.sh"
  if HQ_PACK_AGENT_HQ_ROOT="$HQ_ROOT" bash "$REPO_DIR/install/install.sh" >/dev/null 2>&1; then
    log "update to v${TARGET_VERSION} applied successfully"
    restore_prev=0
  else
    log "new install.sh FAILED (exit $?); rolling back to v${CURRENT_VERSION:-prev}"
    restore_prev=1
  fi
fi

# --- Rollback path. ---
if [ "${restore_prev:-0}" = "1" ] && [ -d "$PREV_DIR" ]; then
  rm -rf "$REPO_DIR" 2>/dev/null
  cp -a "$PREV_DIR" "$REPO_DIR" 2>/dev/null
  if [ -f "$REPO_DIR/install/install.sh" ]; then
    HQ_PACK_AGENT_HQ_ROOT="$HQ_ROOT" bash "$REPO_DIR/install/install.sh" >/dev/null 2>&1 \
      && log "rollback to v${CURRENT_VERSION:-prev} succeeded" \
      || log "rollback re-install returned non-zero (state may need manual repair)"
  fi
fi

# Keep prev/ around as the last-good snapshot; do not delete.
exit 0
