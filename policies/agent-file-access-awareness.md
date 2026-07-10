---
id: agent-file-access-awareness
title: Know who can access a company file — and who in the channel cannot
scope: agent
audience: agent-only
on: [PreToolUse]
enforcement: soft
version: 2
package: hq-pack-agent
---

## Rule

Before an agent repeats the contents of a company file in a channel, it must
know who can access that file relative to the people in the channel:

1. When you read a file under `companies/<slug>/`, an access note is injected
   (from `hq files acl`) listing which of the **current Slack channel members**
   have access and which do **not**.
2. If any channel member lacks access, **do not share the file's contents in
   that channel** — summarize only what those members are already cleared to
   see, or move the discussion somewhere everyone present is authorized.
3. The injected list is **not exhaustive** (person/group grants may be
   unresolved). When in doubt, run the exact `hq files acl … --company …`
   command shown in the note before sharing.
4. Company-scoped content never crosses into another company's channel.

This is agent-only and complements HQ's tenant-boundary non-negotiables.
