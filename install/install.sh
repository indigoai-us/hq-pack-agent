#!/bin/bash
# install.sh — idempotent installer for hq-pack-agent.
#
# Wires the package into an agent's HQ WITHOUT touching any core file:
#   * copies the package payload into $HQ/workspace/.hq-pack-agent/pkg/ (a stable,
#     package-owned location, decoupled from the source checkout);
#   * registers its hooks in $HQ/.claude/settings.local.json — the LOCAL overlay
#     that Claude Code merges with core hooks — so core .claude/settings.json is
#     never modified. Every hook routes through the package's own gate
#     (agent-pack-gate.sh), which no-ops in human sessions;
#   * stamps the installed VERSION.
#
# Idempotent: running twice yields identical files + settings (we strip our own
# prior entries before re-adding). Reversible: install.sh's inverse is
# uninstall.sh, which restores the host byte-identical to pre-install.
#
# Exit 0 on success. Non-zero ONLY on a hard failure (so do-update.sh's rollback
# can detect a bad release). Never blocks a session (it runs at install time, not
# in a hook path).

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"   # package root
err() { printf '[hq-pack-agent install] %s\n' "$*" >&2; }

# --- Resolve HQ root ---
HQ_ROOT="${HQ_PACK_AGENT_HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$HQ_ROOT" ]; then
  # Walk up from cwd looking for a .claude dir.
  d="$(pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -d "$d/.claude" ] && { HQ_ROOT="$d"; break; }
    d="$(dirname "$d")"
  done
fi
if [ -z "$HQ_ROOT" ] || [ ! -d "$HQ_ROOT/.claude" ]; then
  err "cannot resolve HQ root (no .claude dir); set HQ_PACK_AGENT_HQ_ROOT"; exit 1
fi

command -v jq >/dev/null 2>&1 || { err "jq is required to wire settings.local.json"; exit 1; }

STATE_DIR="$HQ_ROOT/workspace/.hq-pack-agent"
INSTALL_DIR="$STATE_DIR/pkg"
SETTINGS="$HQ_ROOT/.claude/settings.local.json"
GATE="$INSTALL_DIR/hooks/agent-pack-gate.sh"
HOOKS_DIR="$INSTALL_DIR/hooks"
MARKER="/.hq-pack-agent/pkg/hooks/agent-pack-gate.sh"   # discriminator for our entries

mkdir -p "$STATE_DIR" "$INSTALL_DIR" || { err "cannot create state dir"; exit 1; }

# --- Copy payload into the stable install dir (exclude dev-only bits) ---
copy_payload() {
  rm -rf "$INSTALL_DIR/hooks" "$INSTALL_DIR/policies" "$INSTALL_DIR/install" 2>/dev/null
  mkdir -p "$INSTALL_DIR/hooks" "$INSTALL_DIR/policies" "$INSTALL_DIR/install"
  cp -a "$SRC/hooks/." "$INSTALL_DIR/hooks/" 2>/dev/null || return 1
  cp -a "$SRC/policies/." "$INSTALL_DIR/policies/" 2>/dev/null || true
  # install/lib (is-agent) + do-update are referenced by the hooks at runtime.
  cp -a "$SRC/install/." "$INSTALL_DIR/install/" 2>/dev/null || return 1
  cp -f "$SRC/VERSION" "$INSTALL_DIR/VERSION" 2>/dev/null || return 1
  chmod +x "$INSTALL_DIR/hooks/"*.sh "$INSTALL_DIR/install/"*.sh 2>/dev/null || true
  return 0
}
copy_payload || { err "payload copy failed"; exit 1; }

# --- Record TRUE pre-install settings state ONCE (survives idempotent re-runs) ---
PREINSTALL_MARK="$STATE_DIR/preinstall-state"
BAK="$STATE_DIR/settings.local.json.preinstall.bak"
if [ ! -f "$PREINSTALL_MARK" ]; then
  if [ -f "$SETTINGS" ]; then
    printf 'present\n' > "$PREINSTALL_MARK"
    cp -f "$SETTINGS" "$BAK"
  else
    printf 'absent\n' > "$PREINSTALL_MARK"
  fi
fi

# --- Wire hooks into settings.local.json (strip-our-own then re-add = idempotent) ---
BASE_JSON='{}'
[ -f "$SETTINGS" ] && BASE_JSON="$(cat "$SETTINGS")"
# Guard against an invalid existing file.
printf '%s' "$BASE_JSON" | jq -e . >/dev/null 2>&1 || BASE_JSON='{}'

NEW_JSON="$(printf '%s' "$BASE_JSON" | jq \
  --arg M "$MARKER" \
  --arg gate "$GATE" \
  --arg dir "$HOOKS_DIR" \
  '
  def strip(arr): (arr // []) | [ .[]
      | .hooks |= (map(select(((.command // "") | contains($M)) | not)))
      | select(((.hooks) // [] | length) > 0) ];
  # Shell-quote the gate + script paths so an HQ root containing spaces or shell
  # metacharacters does not split the command into the wrong argv (the command
  # string is run via sh -c by Claude Code). The hook id is a fixed safe token.
  def cmd(id; file; t): {type:"command", command: ("\"" + $gate + "\" " + id + " \"" + $dir + "/" + file + "\""), timeout: t};
  .hooks = (.hooks // {})
  | .hooks.SessionStart     = ( strip(.hooks.SessionStart)
        + [ {hooks: [ cmd("agent-pack-update"; "agent-pack-update.sh"; 15),
                      cmd("agent-pack-policies"; "agent-pack-policies.sh"; 10),
                      cmd("agent-slack-context"; "agent-slack-context.sh"; 10),
                      cmd("agent-startwork"; "agent-startwork.sh"; 10) ]} ] )
  | .hooks.UserPromptSubmit = ( strip(.hooks.UserPromptSubmit)
        + [ {matcher:"", hooks: [ cmd("agent-plan-clarify"; "agent-plan-clarify.sh"; 10) ]} ] )
  | .hooks.PreToolUse       = ( strip(.hooks.PreToolUse)
        + [ {matcher:"Bash", hooks: [ cmd("agent-slack-guard"; "agent-slack-guard.sh"; 10) ]},
            {matcher:"Read", hooks: [ cmd("agent-company-file-access"; "agent-company-file-access.sh"; 12) ]} ] )
  | .hooks.PostToolUse      = ( strip(.hooks.PostToolUse) )
  | .hooks.PreCompact       = ( strip(.hooks.PreCompact)
        + [ {hooks: [ cmd("agent-learn-handoff"; "agent-learn-handoff.sh"; 10) ]} ] )
  | .hooks.SessionEnd       = ( strip(.hooks.SessionEnd)
        + [ {hooks: [ cmd("agent-learn-handoff"; "agent-learn-handoff.sh"; 10) ]} ] )
  ' 2>/dev/null)"

if [ -z "$NEW_JSON" ] || ! printf '%s' "$NEW_JSON" | jq -e . >/dev/null 2>&1; then
  err "failed to compute settings.local.json update"; exit 1
fi
mkdir -p "$(dirname "$SETTINGS")"
printf '%s\n' "$NEW_JSON" | jq . > "$SETTINGS" || { err "failed to write settings"; exit 1; }

# --- Stamp installed version ---
cp -f "$SRC/VERSION" "$STATE_DIR/installed-version" 2>/dev/null || true

err "installed hq-pack-agent v$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null) into $HQ_ROOT (agent-gated, human-inert)"
exit 0
