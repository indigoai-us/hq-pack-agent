#!/bin/bash
# agent-pack-update.sh — SessionStart self-update hook for hq-pack-agent.
#
# The crux of the package: it ships INSIDE the package and is re-installed on
# every update, so the package can upgrade its own update logic over time.
#
# On each agent session start:
#   1. Gate on agent-only (handled by agent-pack-gate.sh, but we re-check so the
#      hook is safe even if invoked directly).
#   2. Throttle: 24h TTL cache in workspace/.hq-pack-agent/last-check.json.
#   3. Resolve auth for the PRIVATE repo (hq-vault deploy token, else gh auth).
#      Missing/invalid auth -> silent no-op (exit 0), never a prompt.
#   4. Compare installed VERSION to the latest GitHub Release tag (semver).
#   5. If newer, spawn a fully DETACHED background updater that pulls the release
#      and re-runs install.sh, backing up the current version first and rolling
#      back if the new install.sh exits non-zero. The update applies to the NEXT
#      session, never this one — a slow network can't block session start.
#   6. Always exit 0. Advisory infra. Every failure is silent, logged only to the
#      package-local debug log. A token is NEVER printed to stdout or the log.
#
# Modeled on .claude/hooks/check-hq-update.sh (trap-exit-0, 24h cache, detached
# background work, version_gt awk compare, advisory banner).

trap 'exit 0' EXIT

# Consume stdin (the gate / master-hook passes it even if empty).
cat >/dev/null 2>&1 || true

{

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Load libs (common + is-agent). Both must be present; degrade to no-op if not.
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
for cand in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$cand" ] && { . "$cand" 2>/dev/null; break; }
done

# (1) Agent-only re-check (belt-and-suspenders; the gate already enforced this).
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

STATE_DIR="$(hqpa_state_dir)"
[ -n "$STATE_DIR" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

CACHE_FILE="$STATE_DIR/last-check.json"
COOLDOWN_STAMP="$STATE_DIR/update.stamp"
CACHE_TTL_SECONDS=86400  # 24h — mirror check-hq-update.sh

RELEASE_REPO="${HQ_PACK_AGENT_RELEASE_REPO:-indigoai-us/hq-pack-agent}"
AUTH_SECRET_NAME="${HQ_PACK_AGENT_AUTH_SECRET:-HQ_PACK_AGENT_DEPLOY_TOKEN}"

# (2) Throttle. If the cache is fresh (<24h), do nothing this session.
if [ -f "$CACHE_FILE" ]; then
  MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s 2>/dev/null || echo 0)
  if [ "$NOW" -gt 0 ] && [ "$((NOW - MTIME))" -lt "$CACHE_TTL_SECONDS" ]; then
    hqpa_log "update-check: throttled (cache fresh)"
    exit 0
  fi
fi

LOCAL_VERSION="$(hqpa_installed_version)"
if [ -z "$LOCAL_VERSION" ]; then
  hqpa_log "update-check: no installed-version stamp; skipping"
  exit 0
fi

# (3) Resolve auth token for the private repo. NEVER echo it. Order:
#   (a) hq-vault secret via `hq secrets get` (preferred).
#   (b) GH_TOKEN / GITHUB_TOKEN already in the environment.
#   (c) `gh auth token` from an authenticated gh.
# If none resolve -> silent no-op. We stamp the cache so we don't retry every
# session on a box that simply has no agent-update auth.
resolve_token() {
  local t=""
  if command -v hq >/dev/null 2>&1; then
    t="$(hq secrets get "$AUTH_SECRET_NAME" 2>/dev/null | tr -d '\r\n')"
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return 0; fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return 0; fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    t="$(gh auth token 2>/dev/null | tr -d '\r\n')"
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  return 1
}

TOKEN="$(resolve_token)"
if [ -z "$TOKEN" ]; then
  hqpa_log "update-check: no private-repo auth available; no-op"
  # Stamp so we honor the TTL and don't hammer this path every session.
  printf '{"latest":"","checkedAt":"%s","note":"no-auth"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" > "$CACHE_FILE" 2>/dev/null || true
  exit 0
fi

# (4) Fetch latest release tag using the token, WITHOUT exposing it. We pass the
# token via GH_TOKEN to a gh subshell (env, not argv) or via an Authorization
# header to curl (header, not URL). No token ever reaches stdout or the log.
fetch_latest_tag() {
  if command -v gh >/dev/null 2>&1; then
    GH_TOKEN="$TOKEN" gh release view -R "$RELEASE_REPO" --json tagName -q .tagName 2>/dev/null && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" \
      "https://api.github.com/repos/$RELEASE_REPO/releases/latest" 2>/dev/null \
      | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1 && return 0
  fi
  return 1
}

RAW_TAG="$(fetch_latest_tag)"
LATEST_VERSION="$(hqpa_semver_of "$RAW_TAG")"

# Always refresh the cache/TTL stamp regardless of the outcome.
printf '{"latest":"%s","checkedAt":"%s"}\n' \
  "$LATEST_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" > "$CACHE_FILE" 2>/dev/null || true

if [ -z "$LATEST_VERSION" ]; then
  hqpa_log "update-check: could not resolve latest release tag (malformed/none); no-op"
  exit 0
fi

if ! hqpa_version_gt "$LATEST_VERSION" "$LOCAL_VERSION"; then
  hqpa_log "update-check: up to date (local=$LOCAL_VERSION latest=$LATEST_VERSION)"
  exit 0
fi

# (5) Newer release available. Spawn the detached updater. A cooldown stamp keeps
# it from relaunching a second updater while one is in flight (or just failed).
if [ -f "$COOLDOWN_STAMP" ]; then
  SMTIME=$(stat -c %Y "$COOLDOWN_STAMP" 2>/dev/null || stat -f %m "$COOLDOWN_STAMP" 2>/dev/null || echo 0)
  NOW=$(date +%s 2>/dev/null || echo 0)
  if [ "$NOW" -gt 0 ] && [ "$((NOW - SMTIME))" -lt "$CACHE_TTL_SECONDS" ]; then
    hqpa_log "update: $LATEST_VERSION available but updater already ran within cooldown; skipping relaunch"
    exit 0
  fi
fi
: > "$COOLDOWN_STAMP" 2>/dev/null || true

UPDATER="$HOOK_DIR/../install/do-update.sh"
if [ ! -f "$UPDATER" ]; then
  hqpa_log "update: updater script missing ($UPDATER); no-op"
  exit 0
fi

HQ_ROOT_FOR_UPDATE="$(hqpa_hq_root)"
# Pass the token through the ENVIRONMENT of the detached child, never as an arg
# (argv is world-readable via ps; env of a detached process is not echoed).
if command -v setsid >/dev/null 2>&1; then
  HQ_PACK_AGENT_HQ_ROOT="$HQ_ROOT_FOR_UPDATE" \
  HQ_PACK_AGENT_RELEASE_REPO="$RELEASE_REPO" \
  HQ_PACK_AGENT_UPDATE_TOKEN="$TOKEN" \
  setsid bash "$UPDATER" "$LATEST_VERSION" >/dev/null 2>&1 < /dev/null &
else
  HQ_PACK_AGENT_HQ_ROOT="$HQ_ROOT_FOR_UPDATE" \
  HQ_PACK_AGENT_RELEASE_REPO="$RELEASE_REPO" \
  HQ_PACK_AGENT_UPDATE_TOKEN="$TOKEN" \
  nohup bash "$UPDATER" "$LATEST_VERSION" >/dev/null 2>&1 < /dev/null &
fi

# (6) Advisory banner (harmless in an agent context; the actual work is detached).
cat <<EOF
<hq-pack-agent-update>
A newer hq-pack-agent release is available.
  installed: v$LOCAL_VERSION
  latest:    v$LATEST_VERSION
The update is being applied in a detached background process and takes effect on
your NEXT session. This session continues on v$LOCAL_VERSION.
</hq-pack-agent-update>
EOF

} 2>/dev/null || true

exit 0
