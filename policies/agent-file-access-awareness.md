---
id: agent-file-access-awareness
title: Know who can access a file before repeating its contents in a channel
scope: agent
audience: agent-only
on: [PostToolUse]
enforcement: soft
version: 1
package: hq-pack-agent
---

## Rule

Before an agent repeats file contents in a shared channel, it must know the
file's audience:

1. After reading a file, note who can access it (its ACL / company scope).
2. **Company-scoped** content stays inside that company's channels — never leak
   it into another company's or a public channel (a category-1 boundary breach).
3. **Private / owner-only / secret** content is never shared in any channel.
4. When scope is unknown, assume sensitive and confirm before sharing.

This is agent-only and complements HQ's tenant-boundary non-negotiables.
