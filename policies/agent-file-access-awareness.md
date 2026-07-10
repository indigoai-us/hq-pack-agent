---
id: agent-file-access-awareness
title: Know who can access a company file — and who in the channel cannot
scope: agent
audience: agent-only
on: [PreToolUse]
enforcement: soft
version: 3
package: hq-pack-agent
---

## Rule

Before an agent repeats the contents of a company file in a channel, it must
know who can access that file relative to the people in the channel:

1. When you read a file under `companies/<slug>/`, an access note is injected
   (from `hq files acl`) listing which of the **current Slack channel members**
   are confirmed to have access and which are **not**.
2. Access follows HQ's **most-specific-match** rule: the single most-specific
   ACL that covers the file decides access; grants on broader ancestor prefixes
   are shadowed when a more-specific ACL exists. The note reflects this and is
   deliberately **conservative** — a member is listed as WITHOUT access unless
   access is positively confirmed.
3. If any channel member is not confirmed to have access, **do not share the
   file's contents in that channel** — summarize only what those members are
   already cleared to see, or move the discussion somewhere everyone present is
   authorized.
4. The note is **not exhaustive** (person/group grants may be unresolved, and
   access is approximated from CLI output). When in doubt, run the exact
   `hq files acl … --company …` command shown before sharing.
5. Company-scoped content never crosses into another company's channel.

This is agent-only and complements HQ's tenant-boundary non-negotiables.
