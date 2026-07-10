#!/bin/bash
# common.sh — shared helpers for hq-pack-agent hooks.
#
# Sourced by every package hook AFTER `trap 'exit 0' EXIT`. Pure library: defines
# functions + a few path vars, produces no output, never exits. Every function is
# written to be safe under a no-`set -e`/no-`set -u` advisory hook.

# --- Resolve HQ root (never assume cwd) ---
hqpa_hq_root() {
  if [ -n "${HQ_PACK_AGENT_HQ_ROOT:-}" ]; then printf '%s' "$HQ_PACK_AGENT_HQ_ROOT"; return 0; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return 0; fi
  # Fall back to three levels up from this lib (…/<install-dir>/hooks/lib/common.sh).
  ( cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd ) || printf ''
}

# --- Package state dir (under workspace/, mirrors check-hq-update's cache home) ---
hqpa_state_dir() {
  local root; root="$(hqpa_hq_root)"
  [ -n "$root" ] || { printf ''; return 0; }
  printf '%s/workspace/.hq-pack-agent' "$root"
}

# --- Debug log (package-local; NEVER stdout, NEVER prints secrets) ---
# Usage: hqpa_log "message"
hqpa_log() {
  local dir; dir="$(hqpa_state_dir)"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  # Redact anything that looks like a token before it ever hits disk.
  local msg; msg="$(printf '%s' "$*" | sed -E 's/(gh[pousr]_[A-Za-z0-9]{6,}|[A-Za-z0-9_-]{40,})/<redacted>/g')"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$msg" \
    >> "$dir/debug.log" 2>/dev/null || true
}

# --- Semver compare (X.Y.Z): hqpa_version_gt A B → 0 when A > B ---
# Byte-for-byte the pattern from .claude/hooks/check-hq-update.sh.
hqpa_version_gt() {
  [ "$1" = "$2" ] && return 1
  local a b
  a=$(printf '%s' "$1" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  b=$(printf '%s' "$2" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  [ "$a" \> "$b" ]
}

# --- Normalize a release tag / version string to bare X.Y.Z (empty if none) ---
hqpa_semver_of() {
  printf '%s' "${1:-}" | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

# --- Installed VERSION (stamped by install.sh), empty if not installed ---
hqpa_installed_version() {
  local dir; dir="$(hqpa_state_dir)"
  [ -n "$dir" ] && [ -f "$dir/installed-version" ] || { printf ''; return 0; }
  hqpa_semver_of "$(head -1 "$dir/installed-version" 2>/dev/null)"
}
