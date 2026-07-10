#!/bin/bash
# agent-learn-handoff.sh — PreCompact / SessionEnd. Forced learning + handoff.
#
# Agents run unattended, so they must persist state on their own cadence. On a
# compaction boundary (or session end) remind the agent to checkpoint, write a
# handoff, and route any reusable rules through /learn before context is lost.
# Advisory context only.

trap 'exit 0' EXIT
cat >/dev/null 2>&1 || true
{
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
for c in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$c" ] && { . "$c" 2>/dev/null; break; }
done
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

cat <<'EOF'
<hq-pack-agent-learn-handoff>
Context is about to compact / the session is ending. Before you lose state:
- Save a checkpoint of what you're mid-way through.
- Write a handoff so the next agent session can resume cleanly.
- Route any reusable rule you discovered through /learn (not inline notes).
Do this now — you are autonomous; nobody else will.
</hq-pack-agent-learn-handoff>
EOF
} 2>/dev/null || true
exit 0
