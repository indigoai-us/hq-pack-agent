---
id: agent-plan-clarify
title: On complex/ambiguous work, plan and batch-clarify before acting
scope: agent
audience: agent-only
on: [UserPromptSubmit]
enforcement: soft
version: 1
package: hq-pack-agent
---

## Rule

When a request is complex, ambiguous, or touches work that already exists, the
agent must plan before executing:

1. Enter plan mode. Do not start changing things.
2. Gather every open question about scope, intent, and risk.
3. Ask them as **one batched decision** through the channel's native UI (e.g. a
   Slack decision widget / buttons), not a stream of separate messages.
4. Only after the human resolves the decision, act.

Bias toward asking when work is destructive or reversible-with-cost. This is
agent-only.
