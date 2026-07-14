#!/bin/bash
# agent-startwork.sh — SessionStart. Begin fresh agent sessions with /startwork.
#
# Core's auto-startwork hook only covers single-company/startup sessions. Agents
# can start outside that path, so make /startwork the first action for every
# fresh agent startup. Resume and compact SessionStart events intentionally stay
# silent: their existing context must not be re-initialized.

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

# SessionStart supplies a JSON payload. Only a genuinely fresh startup needs
# initialization; resume/compact events should preserve their existing state.
SOURCE="$(printf '%s' "$INPUT" | tr '\n' ' ' | sed -nE 's/.*"source"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
[ "$SOURCE" = "startup" ] || exit 0

# Agent runtimes may provide the target company under either general or
# agent-specific names. It is optional: /startwork resolves the active context
# itself when no company is supplied.
COMPANY="${HQ_COMPANY:-${HQ_AGENT_COMPANY:-${HQ_COMPANY_SLUG:-}}}"

echo "<hq-pack-agent-startwork>"
if [ -n "$COMPANY" ]; then
  echo "This is a fresh autonomous agent session. Run /startwork ${COMPANY} as your FIRST action now, before any investigation, response, or tool use. Do not defer it."
else
  echo "This is a fresh autonomous agent session. Run /startwork as your FIRST action now, before any investigation, response, or tool use. Do not defer it."
fi
echo "</hq-pack-agent-startwork>"
} 2>/dev/null || true
exit 0
