#!/bin/bash
# agent-slack-guard.sh — PreToolUse(Bash). Enforce plain, short outbound chat.
#
# When an agent is about to send an outbound message (Slack chat.postMessage,
# telegram sendMessage, an `hq dm` / slack CLI, etc.), inject a reminder to run
# the text through the markdown-strip transform and keep replies short + human +
# link-to-detail. Advisory only: it adds context, it never blocks the send.
#
# We detect "outbound message" from the Bash command text conservatively — only
# on clear message-send signatures — so unrelated Bash is untouched.

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

# Pull the command string out of the PreToolUse payload (json). Fallback: raw.
CMD="$(printf '%s' "$INPUT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(.*)".*/\1/p' | head -1)"
[ -n "$CMD" ] || CMD="$INPUT"

case "$CMD" in
  *chat.postMessage*|*sendMessage*|*"slack "*|*"hq dm"*|*"/messages"*|*postEphemeral*)
    cat <<'EOF'
<hq-pack-agent-slack-guard>
Outbound message detected. Before sending:
- Run the body through the markdown-strip transform (plain text — no **bold**,
  no `backtick` variable styling, no headings, no code fences, no tables).
- Keep it short and human: one clear line or two, not a wall of text.
- Push detail behind a link instead of pasting it inline.
- Match the destination channel's voice profile (Slack/Telegram/email/SMS).
EOF
    ;;
esac
} 2>/dev/null || true
exit 0
