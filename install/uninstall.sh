#!/bin/bash
# uninstall.sh — exact inverse of install.sh.
#
# Removes every file and settings entry the package added and leaves the host HQ
# byte-identical to its pre-install state:
#   * strips our hook entries from .claude/settings.local.json (identified by the
#     gate-path marker), dropping any event arrays we created that become empty;
#   * if that leaves the file semantically equal to the recorded pre-install
#     backup, restores the backup VERBATIM (byte-identical). If pre-install had no
#     such file and nothing else remains, deletes it (byte-identical absence). If
#     the user made unrelated changes since install, keeps the surgically-cleaned
#     version so their edits survive;
#   * removes the package-owned state dir (workspace/.hq-pack-agent), which did
#     not exist before install.
#
# Idempotent and safe to run when not installed. Always exits 0.

set -uo pipefail
err() { printf '[hq-pack-agent uninstall] %s\n' "$*" >&2; }

HQ_ROOT="${HQ_PACK_AGENT_HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$HQ_ROOT" ]; then
  d="$(pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -d "$d/.claude" ] && { HQ_ROOT="$d"; break; }
    d="$(dirname "$d")"
  done
fi
[ -n "$HQ_ROOT" ] && [ -d "$HQ_ROOT/.claude" ] || { err "cannot resolve HQ root; nothing to do"; exit 0; }

STATE_DIR="$HQ_ROOT/workspace/.hq-pack-agent"
SETTINGS="$HQ_ROOT/.claude/settings.local.json"
BAK="$STATE_DIR/settings.local.json.preinstall.bak"
PREINSTALL_MARK="$STATE_DIR/preinstall-state"
MARKER="/.hq-pack-agent/pkg/hooks/agent-pack-gate.sh"

PREINSTALL_STATE="unknown"
[ -f "$PREINSTALL_MARK" ] && PREINSTALL_STATE="$(tr -d '[:space:]' < "$PREINSTALL_MARK" 2>/dev/null)"

if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  # Strip our entries; drop event arrays that become empty; drop .hooks if empty.
  CLEANED="$(jq \
    --arg M "$MARKER" '
    def strip(arr): (arr // []) | [ .[]
        | .hooks |= (map(select(((.command // "") | contains($M)) | not)))
        | select(((.hooks) // [] | length) > 0) ];
    if has("hooks") then
      .hooks |= ( to_entries
        | map(.value = strip(.value))
        | map(select((.value | length) > 0))
        | from_entries )
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
    ' "$SETTINGS" 2>/dev/null)"

  if [ -n "$CLEANED" ] && printf '%s' "$CLEANED" | jq -e . >/dev/null 2>&1; then
    if [ "$PREINSTALL_STATE" = "present" ] && [ -f "$BAK" ]; then
      # Byte-identical restore when nothing else changed since install.
      if [ "$(printf '%s' "$CLEANED" | jq -S .)" = "$(jq -S . "$BAK" 2>/dev/null)" ]; then
        cp -f "$BAK" "$SETTINGS"
      else
        printf '%s\n' "$CLEANED" | jq . > "$SETTINGS"
      fi
    else
      # Pre-install had no local settings. If nothing but an empty object remains,
      # remove the file entirely to restore byte-identical absence.
      if [ "$(printf '%s' "$CLEANED" | jq -cS .)" = "{}" ]; then
        rm -f "$SETTINGS"
      else
        printf '%s\n' "$CLEANED" | jq . > "$SETTINGS"
      fi
    fi
  fi
fi

# Remove the package-owned state dir (repo checkout, pkg copy, caches, backup).
rm -rf "$STATE_DIR" 2>/dev/null || true

err "removed hq-pack-agent from $HQ_ROOT"
exit 0
