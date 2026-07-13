#!/bin/bash
# agent-slack-guard.sh — PreToolUse(Bash). Keep outbound chat plain + short, and
# HARD-BLOCK a wall-of-text send (redirect the agent to /deploy for anything long).
#
# When an agent is about to send an outbound message (Slack chat.postMessage,
# telegram sendMessage, an `hq dm` / slack CLI, etc.):
#   * if the send is LONG (over HQ_SLACK_MAX_REPLY_CHARS, default 2000), BLOCK it
#     (exit 2) and tell the agent to publish via the /deploy skill and reply with
#     just a short summary + the share link — chat channels are for short, human
#     messages, not pasted documents.
#   * otherwise stay ADVISORY: inject a reminder to strip markdown + keep it short.
#
# We detect "outbound message" from the Bash command text conservatively — only on
# clear message-send signatures — so unrelated Bash is untouched. Fail-OPEN: any
# error, or a human/non-agent session, is a silent no-op (never blocks a send).

trap 'exit 0' EXIT
INPUT="$(cat 2>/dev/null || true)"

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

# Only act on clear outbound-message sends; everything else is inert.
case "$CMD" in
  *chat.postMessage*|*sendMessage*|*"slack "*|*"hq dm"*|*"/messages"*|*postEphemeral*) ;;
  *) exit 0 ;;
esac

# HARD BLOCK: a wall-of-text reply. The command carrying a long inline message is
# itself long, so measuring the command length is a robust proxy that needs no
# fragile body parsing. Long structured/blocks payloads count too — those belong
# in a published artifact, not pasted into a channel.
MAX="${HQ_SLACK_MAX_REPLY_CHARS:-2000}"
case "$MAX" in *[!0-9]*|"") MAX=2000 ;; esac
LEN=${#CMD}
if [ "$LEN" -gt "$MAX" ]; then
  trap - EXIT
  printf '%s\n' "<hq-pack-agent-slack-guard>
BLOCKED: this outbound message is ~${LEN} characters — too long to post to a chat channel.
Do NOT paste a wall of text into Slack/DM/Telegram. Instead:
  1. Publish the full content with the /deploy skill (or /hq-share for a vault path).
  2. Send ONLY a 1-2 line summary plus the share link.
Re-run your send with the short version. (Limit: HQ_SLACK_MAX_REPLY_CHARS=${MAX}.)
</hq-pack-agent-slack-guard>" >&2
  exit 2
fi

# ADVISORY (normal length): plain, short, link-to-detail.
cat <<'EOF'
<hq-pack-agent-slack-guard>
Outbound message detected. Before sending:
- Run the body through the markdown-strip transform (plain text — no **bold**,
  no `backtick` variable styling, no headings, no code fences, no tables).
- Keep it short and human: one clear line or two, not a wall of text.
- Push detail behind a link instead of pasting it inline.
- Match the destination channel's voice profile (Slack/Telegram/email/SMS).
</hq-pack-agent-slack-guard>
EOF
exit 0
