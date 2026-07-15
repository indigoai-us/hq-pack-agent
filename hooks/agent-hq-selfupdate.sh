#!/bin/bash
# agent-hq-selfupdate.sh — SessionStart maintenance hook for autonomous agents.
#
# SessionStart must never wait on npm or GitHub. The foreground invocation does
# only the agent gate and 24-hour throttle, then detaches every version check.

trap 'exit 0' EXIT

run_background() {
  local hook_dir="$1" state_dir="$2"
  local hq_root cache_file cli_stamp core_stamp
  local cooldown_seconds=21600

  [ -n "$hook_dir" ] && [ -n "$state_dir" ] || return 0
  . "$hook_dir/lib/common.sh" 2>/dev/null || return 0

  # Resolve the root only after SessionStart has been released.
  hq_root="$(hqpa_hq_root)"
  [ -n "$hq_root" ] || hq_root="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$hq_root" ] || return 0

  cache_file="$state_dir/hq-selfupdate-last-check.json"
  cli_stamp="$state_dir/hq-cli-auto-update.stamp"
  core_stamp="$state_dir/hq-core-rescue.stamp"

  stamp_is_fresh() {
    [ -f "$1" ] || return 1
    local mtime now
    mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    [ "$now" -gt 0 ] && [ "$((now - mtime))" -lt "$2" ]
  }

  # --- (1) hq CLI: compare local binary with the latest npm package version. ---
  local local_cli_version latest_cli_raw latest_cli_version
  local_cli_version=""
  latest_cli_version=""
  if command -v hq >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local_cli_version="$(HQ_NO_UPDATE_CHECK=1 hq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$local_cli_version" ]; then
      latest_cli_raw=""
      # GNU timeout gives this network check a hard upper bound. npm's own short
      # retry settings are the portable fallback for hosts without timeout.
      if command -v timeout >/dev/null 2>&1; then
        latest_cli_raw="$(timeout 8 npm view @indigoai-us/hq-cli version 2>/dev/null)" || latest_cli_raw=""
      else
        latest_cli_raw="$(npm view @indigoai-us/hq-cli version --fetch-timeout=8000 --fetch-retries=0 --fetch-retry-mintimeout=1000 --fetch-retry-maxtimeout=1000 2>/dev/null)" || latest_cli_raw=""
      fi
      latest_cli_version="$(hqpa_semver_of "$latest_cli_raw")"

      if [ -n "$latest_cli_version" ] && hqpa_version_gt "$latest_cli_version" "$local_cli_version"; then
        if stamp_is_fresh "$cli_stamp" "$cooldown_seconds"; then
          hqpa_log "hq-cli-auto-update: $latest_cli_version available but cooldown is active"
        else
          : > "$cli_stamp" 2>/dev/null || true
          # Detach fully so npm cannot hold up the detached version-check body.
          if command -v setsid >/dev/null 2>&1; then
            setsid sh -c 'npm install -g @indigoai-us/hq-cli@latest >/dev/null 2>&1' >/dev/null 2>&1 < /dev/null &
          else
            nohup sh -c 'npm install -g @indigoai-us/hq-cli@latest >/dev/null 2>&1' >/dev/null 2>&1 < /dev/null &
          fi
          hqpa_log "hq-cli update scheduled $local_cli_version->$latest_cli_version"
        fi
      elif [ -z "$latest_cli_version" ]; then
        hqpa_log "hq-cli-auto-update: could not resolve latest npm version"
      fi
    else
      hqpa_log "hq-cli-auto-update: could not read local hq version"
    fi
  fi

  # --- (2) hq-core: compare core.yaml to the latest public GitHub release. ---
  local core_yaml local_core_version latest_core_version raw_core_tag
  core_yaml="$hq_root/core/core.yaml"
  local_core_version=""
  latest_core_version=""

  if [ -f "$core_yaml" ]; then
    local_core_version="$(grep -E '^hqVersion:' "$core_yaml" 2>/dev/null | head -1 | sed -E 's/^hqVersion:[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*/\1/')"
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

  if [ -n "$local_core_version" ]; then
    raw_core_tag="$(fetch_latest_core_release)" || raw_core_tag=""
    latest_core_version="$(hqpa_semver_of "$raw_core_tag")"

    if [ -n "$latest_core_version" ] && hqpa_version_gt "$latest_core_version" "$local_core_version"; then
      if ! command -v hq >/dev/null 2>&1; then
        hqpa_log "hq-core-auto-update: hq command missing; cannot run rescue"
      elif stamp_is_fresh "$core_stamp" "$cooldown_seconds"; then
        hqpa_log "hq-core-auto-update: $latest_core_version available but rescue cooldown is active"
      else
        : > "$core_stamp" 2>/dev/null || true
        # Pass the root as a positional parameter so it is never shell-expanded.
        if command -v setsid >/dev/null 2>&1; then
          setsid sh -c 'hq rescue --hq-root "$1" --yes >/dev/null 2>&1' sh "$hq_root" >/dev/null 2>&1 < /dev/null &
        else
          nohup sh -c 'hq rescue --hq-root "$1" --yes >/dev/null 2>&1' sh "$hq_root" >/dev/null 2>&1 < /dev/null &
        fi
        hqpa_log "hq rescue scheduled $local_core_version->$latest_core_version"
      fi
    elif [ -n "$latest_core_version" ]; then
      # A successful rescue makes the stamp irrelevant once core.yaml catches up.
      rm -f "$core_stamp" 2>/dev/null || true
    else
      hqpa_log "hq-core-auto-update: could not resolve latest release version"
    fi
  elif [ -f "$core_yaml" ]; then
    hqpa_log "hq-core-auto-update: could not read local hqVersion"
  fi

  # The foreground path updates the mtime before forking. Keep the diagnostic
  # payload too, without making a failed lookup repeat on every SessionStart.
  printf '{"latest":"%s","checkedAt":"%s"}\n' \
    "$latest_core_version" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" > "$cache_file" 2>/dev/null || true
}

# The detached process re-enters this file in background mode. It intentionally
# skips stdin consumption, agent gating, and the TTL check already done above.
if [ "${1:-}" = "--hq-selfupdate-background" ]; then
  run_background "${2:-}" "${3:-}"
  exit 0
fi

# Consume stdin (the gate / master-hook passes it even if empty).
cat >/dev/null 2>&1 || true

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Load libs (common + is-agent). Both must be present; degrade to no-op if not.
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
for cand in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$cand" ] && { . "$cand" 2>/dev/null; break; }
done

# Belt-and-suspenders: the package gate already restricts this to agents.
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

# Resolving and creating the package state is local-only. The HQ root needed by
# the core check is deliberately resolved by run_background after this returns.
STATE_DIR="$(hqpa_state_dir)"
[ -n "$STATE_DIR" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

CACHE_FILE="$STATE_DIR/hq-selfupdate-last-check.json"
CACHE_TTL_SECONDS=86400  # 24h

# One SessionStart check per day. The mtime is written before the fork so a
# second session cannot launch another detached check while this one is running.
if [ -f "$CACHE_FILE" ]; then
  MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s 2>/dev/null || echo 0)
  if [ "$NOW" -gt 0 ] && [ "$((NOW - MTIME))" -lt "$CACHE_TTL_SECONDS" ]; then
    exit 0
  fi
fi
: > "$CACHE_FILE" 2>/dev/null || exit 0

# Detach the complete lookup body. It has no SessionStart stdout: outcomes are
# recorded with hqpa_log and the install/rescue actions detach again within it.
HOOK_SCRIPT="$HOOK_DIR/agent-hq-selfupdate.sh"
if command -v setsid >/dev/null 2>&1; then
  setsid sh -c 'exec "$1" --hq-selfupdate-background "$2" "$3"' sh "$HOOK_SCRIPT" "$HOOK_DIR" "$STATE_DIR" >/dev/null 2>&1 < /dev/null &
else
  nohup sh -c 'exec "$1" --hq-selfupdate-background "$2" "$3"' sh "$HOOK_SCRIPT" "$HOOK_DIR" "$STATE_DIR" >/dev/null 2>&1 < /dev/null &
fi

exit 0
