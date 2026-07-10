#!/bin/bash
# agent-file-access.sh — PostToolUse(Read). File-access awareness for agents.
#
# After an agent reads a file, tell it WHO can access that file, so it knows
# whether the content is safe to repeat in a shared channel. Advisory context
# only. Best-effort ACL resolution via the `hq` CLI; if unavailable, fall back to
# a conservative sensitivity heuristic on the path.

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

FILE="$(printf '%s' "$INPUT" | sed -nE 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -n "$FILE" ] || exit 0

audience=""
# Prefer a real ACL answer from HQ when the file lives in the vault.
if command -v hq >/dev/null 2>&1; then
  audience="$(hq files acl "$FILE" 2>/dev/null | head -3 | tr '\n' ' ')"
fi
if [ -z "$audience" ]; then
  case "$FILE" in
    *companies/*) audience="company-scoped — visible to members of that company only. Do NOT leak into another company's channel." ;;
    *personal/*|*/.hq/*|*secrets*|*credential*) audience="private/owner-only — treat as sensitive; do NOT share in any channel." ;;
    *core/*|*repos/public/*) audience="shared/public — generally safe to reference." ;;
    *) audience="scope unknown — assume sensitive until confirmed before sharing." ;;
  esac
fi

cat <<EOF
<hq-pack-agent-file-access>
Access note for the file you just read ($FILE):
  audience: $audience
Consider this before repeating its contents in a shared channel.
</hq-pack-agent-file-access>
EOF
} 2>/dev/null || true
exit 0
