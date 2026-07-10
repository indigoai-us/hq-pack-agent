#!/bin/bash
# agent-slack-context.sh — SessionStart. Surface the Slack session context.
#
# When an agent session was spawned to handle a Slack message, hq-pro passes in
# (at spawn) who sent the message and who else is in the channel, with emails
# (see hooks/lib/slack-context.sh for the contract). This hook reads that and
# tells the agent, at the very start:
#   * exactly which email/Slack user sent the triggering message, and
#   * who else is currently in the channel (with emails),
# so the agent knows its audience before it reads files or replies. The Read
# hook (agent-company-file-access.sh) then cross-references this roster against
# each company file's ACL.
#
# Agent-only (gated) and advisory. Silent no-op when there is no Slack context
# (e.g. a non-Slack agent session).

trap 'exit 0' EXIT
cat >/dev/null 2>&1 || true
{
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
. "$HOOK_DIR/lib/slack-context.sh" 2>/dev/null || exit 0
for c in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$c" ] && { . "$c" 2>/dev/null; break; }
done
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0

DUMP="$(hqpa_slack_dump)"
[ -n "$DUMP" ] || exit 0   # no Slack context — not a Slack session

CHANNEL_ID="$(printf '%s\n' "$DUMP"   | awk -F'\t' '$1=="CHANNEL_ID"{print $2; exit}')"
CHANNEL_NAME="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="CHANNEL_NAME"{print $2; exit}')"
SENDER_EMAIL="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="SENDER_EMAIL"{print $2; exit}')"
MEMBERS="$(printf '%s\n' "$DUMP"      | awk -F'\t' '$1=="MEMBER"{print $2}')"

chan_label="${CHANNEL_NAME:+#$CHANNEL_NAME}"
[ -n "$chan_label" ] || chan_label="${CHANNEL_ID:-this channel}"

echo "<hq-pack-agent-slack-context>"
if [ -n "$SENDER_EMAIL" ]; then
  echo "This Slack session was triggered by ${SENDER_EMAIL} in ${chan_label}."
else
  echo "This is a Slack session in ${chan_label} (sender email unavailable)."
fi
if [ -n "$MEMBERS" ]; then
  echo "Everyone currently in the channel (by email):"
  printf '%s\n' "$MEMBERS" | sed 's/^/  - /'
  echo
  echo "Anything you post here is visible to ALL of the above. Before sharing the"
  echo "contents of any company file, check the per-file access note (injected when"
  echo "you read it) — some channel members may not have access to that file."
fi
echo "</hq-pack-agent-slack-context>"
} 2>/dev/null || true
exit 0
