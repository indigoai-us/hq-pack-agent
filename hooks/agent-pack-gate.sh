#!/bin/bash
# agent-pack-gate.sh — hq-pack-agent's own hook gate.
#
# Usage: agent-pack-gate.sh <hook-id> <actual-hook-script> [args...]
#
# Every package hook is registered in the host's settings overlay THROUGH this
# gate (never directly), mirroring how core hooks route through hook-gate.sh. We
# ship our own gate rather than editing core hook-gate.sh because:
#   * core hook-gate.sh has a hardcoded profile allowlist — an unknown id is
#     silently skipped, so registering there would make our hooks no-op;
#   * editing a core file breaks "byte-identical uninstall" and is clobbered by
#     /update-hq. A package-owned gate keeps the whole package self-contained.
#
# Responsibilities:
#   1. Agent-only gate: if not a genuine agent session, pass through (exit 0)
#      WITHOUT running the hook. This is the single choke point that guarantees
#      inertness in human sessions even if a hook forgets to self-gate.
#   2. Disable support: HQ_PACK_AGENT_DISABLED_HOOKS (comma-sep ids) skips a hook.
#   3. PATH hardening so delegated hooks find gh/hq/git/node.
#   4. Advisory discipline: consume stdin, never crash the session. A missing or
#      failing delegated hook is swallowed (exit 0) — this gate never blocks.
#
# NOTE: PreToolUse hooks that legitimately need to BLOCK (exit 2) still can — the
# delegated script's non-zero exit is passed through. But the *gate itself* only
# ever fails closed to "skip" (exit 0); it never invents a block.

trap 'exit 0' EXIT

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Locate is-agent.sh (installed alongside the package under install/lib, but the
# hooks dir is copied next to it; support both repo and installed layouts).
for cand in \
  "$GATE_DIR/lib/is-agent.sh" \
  "$GATE_DIR/../install/lib/is-agent.sh" \
  "$GATE_DIR/../lib/is-agent.sh"; do
  if [ -f "$cand" ]; then . "$cand" 2>/dev/null; break; fi
done

# If detection couldn't load, DEFAULT TO NOT-AN-AGENT (stay inert). Consume stdin
# so the caller isn't left with a dangling pipe, then pass through.
if ! command -v hq_is_agent_session >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

HOOK_ID="${1:-}"
HOOK_SCRIPT="${2:-}"
[ $# -ge 2 ] && shift 2

# (1) Agent-only gate.
if ! hq_is_agent_session; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

# (2) Explicit disable list.
if [ -n "${HQ_PACK_AGENT_DISABLED_HOOKS:-}" ]; then
  IFS=',' read -ra _disabled <<<"$HQ_PACK_AGENT_DISABLED_HOOKS"
  for d in "${_disabled[@]}"; do
    d="$(printf '%s' "$d" | tr -d '[:space:]')"
    if [ "$d" = "$HOOK_ID" ]; then
      cat >/dev/null 2>&1 || true
      exit 0
    fi
  done
fi

# (3) PATH hardening (best-effort; keep existing PATH first).
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.npm-global/bin"

# (4) Delegate. A missing script is a silent skip, not a crash.
if [ -z "$HOOK_SCRIPT" ] || [ ! -f "$HOOK_SCRIPT" ]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

# Pass through a DELIBERATE PreToolUse block (exit 2) so a hook can veto a tool
# call (e.g. agent-slack-guard blocking a wall-of-text send). ANY OTHER non-zero
# is an accidental hook error and fails OPEN to a skip (exit 0) so a buggy hook can
# never wedge the session. NB: `exit $?` alone would be eaten by the EXIT trap
# above (an EXIT trap that calls `exit` overrides the pending status), so the block
# path clears the trap first.
bash "$HOOK_SCRIPT" "$@"
rc=$?
if [ "$rc" -eq 2 ]; then
  trap - EXIT
  exit 2
fi
exit 0
