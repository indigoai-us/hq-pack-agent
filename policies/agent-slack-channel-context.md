---
id: agent-slack-channel-context
title: Know exactly who sent the Slack message and who else is in the channel
scope: agent
audience: agent-only
on: [SessionStart]
enforcement: soft
version: 1
package: hq-pack-agent
---

## Rule

When an agent session handles a Slack message, it is told at the very start:

1. The **email of the person who sent** the triggering message.
2. The **emails of everyone else currently in the channel**.

Treat that roster as the audience for anything you post: every message in the
channel is visible to all of them. Use it together with the per-file access
note (see `agent-file-access-awareness`) to decide what is safe to share — never
paste content that some channel member is not authorized to see.

This is agent-only.
