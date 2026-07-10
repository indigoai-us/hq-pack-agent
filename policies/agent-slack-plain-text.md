---
id: agent-slack-plain-text
title: Outbound agent messages are short, plain-text, human — link to detail
scope: agent
audience: agent-only
on: [PreToolUse]
enforcement: soft
version: 1
package: hq-pack-agent
---

## Rule

When an HQ agent sends a message to a human channel (Slack, Telegram, email,
SMS), the message must be plain and human:

1. **No markdown formatting.** Strip `**bold**`, `_italics_`, `` `backtick` ``
   "orange variable-name" styling, `#` headings, code fences, and tables. Run the
   text through the markdown-strip transform (`hooks/lib/markdown-strip.sh`).
2. **Short.** One or two clear sentences beat a wall of text. Say the outcome.
3. **Link to detail.** Put anything long (logs, diffs, full reports) behind a
   link or a thread, not inline.
4. **Human tone.** Write like a teammate, not a machine reading a log.

This is agent-only: it never applies to human HQ sessions.
