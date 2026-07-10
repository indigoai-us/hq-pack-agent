#!/bin/bash
# agent-pack-policies.sh — SessionStart. Inject the agent-only policy pack.
#
# Human sessions never reach here (agent-pack-gate.sh gates first, and we re-check
# below). For a genuine agent session, surface the package's policy rules as
# session context so the agent adopts the agent-only voice/behavior. This is how
# the policies stay INVISIBLE to human users: they live in the package, not in
# core/policies, and are injected only when is-agent.

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

POLICY_DIR="$HOOK_DIR/../policies"
[ -d "$POLICY_DIR" ] || exit 0

echo "<hq-pack-agent-policies>"
echo "You are running as an HQ AGENT (autonomous worker). The following agent-only"
echo "rules are active for this session (they do NOT apply to human HQ sessions):"
echo
for p in "$POLICY_DIR"/*.md; do
  [ -f "$p" ] || continue
  title="$(sed -nE 's/^title:[[:space:]]*//p' "$p" | head -1)"
  id="$(sed -nE 's/^id:[[:space:]]*//p' "$p" | head -1)"
  [ -n "$title" ] || title="$(basename "$p" .md)"
  printf -- '- [%s] %s\n' "${id:-$(basename "$p" .md)}" "$title"
done
echo
echo "Full rule text lives in the package under policies/. Honor all of them."
echo "</hq-pack-agent-policies>"
} 2>/dev/null || true
exit 0
