#!/bin/bash
# agent-hq-selfupdate.sh — SessionStart maintenance hook for autonomous agents.
#
# Agents are unattended, so keep their hq CLI and hq-core current without asking
# them to act. Everything expensive runs fully detached; this hook only emits a
# compact advisory and always exits 0.

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

# Belt-and-suspenders: the package gate already restricts this to agents.
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

HQ_ROOT="$(hqpa_hq_root)"
[ -n "$HQ_ROOT" ] || HQ_ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$HQ_ROOT" ] || exit 0

STATE_DIR="$(hqpa_state_dir)"
[ -n "$STATE_DIR" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

CACHE_FILE="$STATE_DIR/hq-selfupdate-last-check.json"
CLI_STAMP="$STATE_DIR/hq-cli-auto-update.stamp"
CORE_STAMP="$STATE_DIR/hq-core-rescue.stamp"
CACHE_TTL_SECONDS=86400  # 24h
COOLDOWN_SECONDS=21600   # 6h

# One SessionStart check per day: do not make any network or subprocess work
# while the cache is fresh.
if [ -f "$CACHE_FILE" ]; then
  MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s 2>/dev/null || echo 0)
  if [ "$NOW" -gt 0 ] && [ "$((NOW - MTIME))" -lt "$CACHE_TTL_SECONDS" ]; then
    hqpa_log "hq-selfupdate: throttled (cache fresh)"
    exit 0
  fi
fi

stamp_is_fresh() {
  [ -f "$1" ] || return 1
  local mtime now
  mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  [ "$now" -gt 0 ] && [ "$((now - mtime))" -lt "$2" ]
}

# --- (1) hq CLI: compare local binary with the latest npm package version. ---
if command -v hq >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  LOCAL_CLI_VERSION="$(HQ_NO_UPDATE_CHECK=1 hq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$LOCAL_CLI_VERSION" ]; then
    LATEST_CLI_RAW=""
    # GNU timeout gives this network check a hard upper bound. npm's own short
    # retry settings are the portable fallback for hosts without timeout.
    if command -v timeout >/dev/null 2>&1; then
      LATEST_CLI_RAW="$(timeout 8 npm view @indigoai-us/hq-cli version 2>/dev/null)" || LATEST_CLI_RAW=""
    else
      LATEST_CLI_RAW="$(npm view @indigoai-us/hq-cli version --fetch-timeout=8000 --fetch-retries=0 --fetch-retry-mintimeout=1000 --fetch-retry-maxtimeout=1000 2>/dev/null)" || LATEST_CLI_RAW=""
    fi
    LATEST_CLI_VERSION="$(hqpa_semver_of "$LATEST_CLI_RAW")"

    if [ -n "$LATEST_CLI_VERSION" ] && hqpa_version_gt "$LATEST_CLI_VERSION" "$LOCAL_CLI_VERSION"; then
      if stamp_is_fresh "$CLI_STAMP" "$COOLDOWN_SECONDS"; then
        hqpa_log "hq-cli-auto-update: $LATEST_CLI_VERSION available but cooldown is active"
      else
        : > "$CLI_STAMP" 2>/dev/null || true
        # Detach fully so npm cannot hold up SessionStart or be killed with it.
        if command -v setsid >/dev/null 2>&1; then
          setsid sh -c 'npm install -g @indigoai-us/hq-cli@latest >/dev/null 2>&1' >/dev/null 2>&1 < /dev/null &
        else
          nohup sh -c 'npm install -g @indigoai-us/hq-cli@latest >/dev/null 2>&1' >/dev/null 2>&1 < /dev/null &
        fi
        cat <<EOF
<hq-cli-auto-update>
hq CLI v$LOCAL_CLI_VERSION is updating to v$LATEST_CLI_VERSION in the background and applies next session.
</hq-cli-auto-update>
EOF
      fi
    elif [ -z "$LATEST_CLI_VERSION" ]; then
      hqpa_log "hq-cli-auto-update: could not resolve latest npm version"
    fi
  else
    hqpa_log "hq-cli-auto-update: could not read local hq version"
  fi
fi

# --- (2) hq-core: compare core.yaml to the latest public GitHub release. ---
CORE_YAML="$HQ_ROOT/core/core.yaml"
LOCAL_CORE_VERSION=""
LATEST_CORE_VERSION=""

if [ -f "$CORE_YAML" ]; then
  LOCAL_CORE_VERSION="$(grep -E '^hqVersion:' "$CORE_YAML" 2>/dev/null | head -1 | sed -E 's/^hqVersion:[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*/\1/')"
fi

fetch_latest_core_release() {
  local raw=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    raw="$(gh release view -R indigoai-us/hq-core --json tagName -q .tagName 2>/dev/null)" || raw=""
    [ -n "$raw" ] && { printf '%s' "$raw"; return 0; }
  fi
  if command -v curl >/dev/null 2>&1; then
    raw="$(curl -fsSL --max-time 8 https://api.github.com/repos/indigoai-us/hq-core/releases/latest 2>/dev/null | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)" || raw=""
    [ -n "$raw" ] && { printf '%s' "$raw"; return 0; }
  fi
  return 1
}

if [ -n "$LOCAL_CORE_VERSION" ]; then
  RAW_CORE_TAG="$(fetch_latest_core_release)" || RAW_CORE_TAG=""
  LATEST_CORE_VERSION="$(hqpa_semver_of "$RAW_CORE_TAG")"

  if [ -n "$LATEST_CORE_VERSION" ] && hqpa_version_gt "$LATEST_CORE_VERSION" "$LOCAL_CORE_VERSION"; then
    if ! command -v hq >/dev/null 2>&1; then
      hqpa_log "hq-core-auto-update: hq command missing; cannot run rescue"
    elif stamp_is_fresh "$CORE_STAMP" "$COOLDOWN_SECONDS"; then
      hqpa_log "hq-core-auto-update: $LATEST_CORE_VERSION available but rescue cooldown is active"
    else
      : > "$CORE_STAMP" 2>/dev/null || true
      # Pass the root as a positional parameter so it is never shell-expanded.
      if command -v setsid >/dev/null 2>&1; then
        setsid sh -c 'hq rescue --hq-root "$1" --yes >/dev/null 2>&1' sh "$HQ_ROOT" >/dev/null 2>&1 < /dev/null &
      else
        nohup sh -c 'hq rescue --hq-root "$1" --yes >/dev/null 2>&1' sh "$HQ_ROOT" >/dev/null 2>&1 < /dev/null &
      fi
      cat <<EOF
<hq-core-auto-update>
hq rescue is updating hq-core in the background (current v$LOCAL_CORE_VERSION -> latest v$LATEST_CORE_VERSION) and applies next session.
</hq-core-auto-update>
EOF
    fi
  elif [ -n "$LATEST_CORE_VERSION" ]; then
    # A successful rescue makes the stamp irrelevant once core.yaml catches up.
    rm -f "$CORE_STAMP" 2>/dev/null || true
  else
    hqpa_log "hq-core-auto-update: could not resolve latest release version"
  fi
elif [ -f "$CORE_YAML" ]; then
  hqpa_log "hq-core-auto-update: could not read local hqVersion"
fi

# Refresh the TTL even when a best-effort version lookup failed, avoiding
# repeated session-start attempts against an unavailable npm/GitHub endpoint.
printf '{"latest":"%s","checkedAt":"%s"}\n' \
  "$LATEST_CORE_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" > "$CACHE_FILE" 2>/dev/null || true

} 2>/dev/null || true

exit 0
