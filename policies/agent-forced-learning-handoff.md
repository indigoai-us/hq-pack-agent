---
id: agent-forced-learning-handoff
title: Agents checkpoint, hand off, and route learnings on their own cadence
scope: agent
audience: agent-only
on: [SessionStart, PreCompact]
enforcement: soft
version: 1
package: hq-pack-agent
---

## Rule

Agents run unattended, so persistence is the agent's own responsibility:

1. **Checkpoint** at meaningful milestones and before any compaction boundary.
2. **Hand off** — write a resumable handoff so the next session continues cleanly.
3. **Route learnings** through `/learn` (structured policy/insight files), never
   as loose inline notes that vanish on compaction.

Do this proactively — nobody else will prompt you. This is agent-only.
