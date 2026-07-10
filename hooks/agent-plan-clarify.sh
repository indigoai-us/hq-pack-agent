#!/bin/bash
# agent-plan-clarify.sh — UserPromptSubmit. Plan-mode / clarify gate for agents.
#
# When an agent receives a request that is complex, ambiguous, or touches work
# that already exists, nudge it to STOP and ask clarifying questions through the
# channel's native decision UI (e.g. Slack widgets) — batching all questions into
# ONE decision prompt — before acting. Advisory: adds context, never blocks.
#
# Heuristic is intentionally loose (it only nudges): trigger on multi-clause or
# vague asks, or words that imply existing work / destructive change.

trap 'exit 0' EXIT
INPUT="$(cat 2>/dev/null || true)"
{
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
for c in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$c" ] && { . "$c" 2>/dev/null; break; }
done
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

PROMPT="$(printf '%s' "$INPUT" | sed -nE 's/.*"prompt"[[:space:]]*:[[:space:]]*"(.*)".*/\1/p' | head -1)"
[ -n "$PROMPT" ] || PROMPT="$INPUT"

lc="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
words="$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')"
ambiguous=0
case "$lc" in
  *" and "*" and "*|*rewrite*|*refactor*|*migrate*|*redesign*|*existing*|*"the current"*|*delete*|*replace*|*overhaul*|*"not sure"*|*maybe*|*"figure out"*)
    ambiguous=1 ;;
esac
[ "${words:-0}" -gt 40 ] && ambiguous=1

if [ "$ambiguous" = "1" ]; then
  cat <<'EOF'
<hq-pack-agent-clarify-gate>
This request looks complex/ambiguous or may touch existing work. Before doing the
work: enter plan mode, gather the open questions, and ask them as ONE batched
decision through the channel's native UI (e.g. a Slack decision widget) — not a
stream of separate messages. Confirm scope, then act.
EOF
fi
} 2>/dev/null || true
exit 0
