# hq-pack-agent

Agent-only behavior for HQ, shipped as one versioned, self-updating package.

`hq-pack-agent` delivers hooks, policies, and (later) skills that activate **only
in genuine HQ agent sessions** — the autonomous Slack / email / cloud workers —
and stay **completely inert in human HQ sessions**. It lives in its own private
GitHub repo (`indigoai-us/hq-pack-agent`), installs itself into an agent's HQ,
and **auto-updates from its own GitHub Releases**. To roll a new behavior to
every agent, cut a release; each agent picks it up on its next session — no
hq-core change, no per-company edit.

## What it ships (v1 behavior payload)

Each behavior is an agent-gated hook plus a policy that documents the rule:

| Behavior | Hook (event) | Policy |
|---|---|---|
| Slack/markdown-strip — short, plain, human, link-to-detail | `agent-slack-guard.sh` (PreToolUse:Bash) + `lib/markdown-strip.sh` | `agent-slack-plain-text` |
| Per-channel voice profile (Slack/Telegram/email/SMS) | injected by `agent-pack-policies.sh` (SessionStart) | `agent-voice-per-channel` |
| Plan-mode / clarify gate — batch questions before acting | `agent-plan-clarify.sh` (UserPromptSubmit) | `agent-plan-clarify` |
| Forced learning + handoff | `agent-learn-handoff.sh` (PreCompact / SessionEnd) | `agent-forced-learning-handoff` |
| Company-file access awareness — who in the Slack channel can/can't see a file | `agent-company-file-access.sh` (PreToolUse:Read) | `agent-file-access-awareness` |
| Slack session context — who sent the message + who's in the channel | `agent-slack-context.sh` (SessionStart) | `agent-slack-channel-context` |

Behaviors are data-driven: a new behavior is a new hook + policy file plus a line
in `install/install.sh`, not an edit to a monolith.

## How it stays agent-only

Every hook is registered through the package's own gate, `agent-pack-gate.sh`,
which sources the single shared detector `install/lib/is-agent.sh` and **passes
through (exit 0) without running the hook in any non-agent session**. Detection
is explicit — agent-runtime env markers (`HQ_AGENT_SESSION`, `HQ_AGENT_SLUG`, …)
or a provisioned `workspace/.hq-pack-agent/agent-identity.json` marker — never a
cwd/hostname heuristic. If the signal is ambiguous, it **defaults to "not an
agent"** so the package stays inert. `HQ_PACK_AGENT_FORCE_AGENT=1` /
`HQ_PACK_AGENT_FORCE_HUMAN=1` force the branch for provisioning and tests.

The policies live **inside the package**, not in `core/policies/`, and are
surfaced only by an agent-gated SessionStart hook — so human sessions never load
them.

## Install

```bash
# one-shot: clone/pull the private repo into the agent's HQ, then install
bash install/bootstrap.sh
# provisioning mode also drops the durable agent-identity marker:
HQ_PACK_AGENT_PROVISION=1 bash install/bootstrap.sh
```

`install/install.sh` (invoked by bootstrap, or run directly against a checkout):

- copies the payload into `workspace/.hq-pack-agent/pkg/` (a stable,
  package-owned location, decoupled from the source checkout);
- registers the hooks in **`.claude/settings.local.json`** — the local overlay
  Claude Code merges with core hooks — so the checked-in core
  `.claude/settings.json` is **never touched**;
- stamps the installed `VERSION`.

It is **idempotent** (running twice yields identical files + settings; prior
entries are stripped before re-adding) and takes an explicit HQ root via
`HQ_PACK_AGENT_HQ_ROOT` (else `CLAUDE_PROJECT_DIR`, else a `.claude`-dir walk).

### Why not `scan-packages.sh` / `contributes:`

`core/scripts/scan-packages.sh` wires a pack's content for the **whole host
population** — human users included — by symlinking skills into `.claude/skills/`
and policies into `core/policies/`. That is the opposite of agent-only, so this
package deliberately omits a `contributes:` block and wires **itself** into the
local overlay through `install.sh` instead. It also ships its **own** gate rather
than editing core `hook-gate.sh`, whose hardcoded profile allowlist would
silently skip unknown hook IDs (and whose edits `/update-hq` would clobber).

## Slack session context (integration contract)

The Slack-aware behaviors read a **channel roster hq-pro passes in at spawn** —
the hook never calls Slack itself. hq-pro resolves the triggering message's
sender and the channel members (with emails) once, at spawn, and hands them to
the agent session in either form (checked in order by `hooks/lib/slack-context.sh`):

1. A JSON file at `$HQ_SLACK_CONTEXT_FILE`, or the default
   `workspace/.hq-pack-agent/slack-context.json`:

   ```json
   {
     "channel": { "id": "C123", "name": "acme-deals" },
     "sender":  { "email": "jacob@corp.com", "slack_id": "U1", "handle": "jacob" },
     "members": [ { "email": "a@corp.com" }, { "email": "b@corp.com" } ]
   }
   ```

2. Env fallback: `HQ_SLACK_CHANNEL_ID`, `HQ_SLACK_CHANNEL_NAME`,
   `HQ_SLACK_SENDER_EMAIL`, `HQ_SLACK_SENDER_HANDLE`,
   `HQ_SLACK_MEMBER_EMAILS` (comma/space separated).

Given this, on each agent session:

- **`agent-slack-context.sh`** (SessionStart) tells the agent exactly which email
  sent the message and who else is in the channel.
- **`agent-company-file-access.sh`** (PreToolUse:Read) — when the agent reads a
  `companies/<slug>/…` file — fetches the file's ACL live (`hq files acl <rel>
  --company <slug>`, resolving company-wide grants via `hq members list`),
  intersects it with the channel roster, and injects: which channel members
  **have** access, which **do not**, a **do-not-share** warning when anyone
  lacks access, and the exact command for the full (non-exhaustive) ACL. ACL and
  membership are cached per session and time-boxed; absent context ⇒ a plain
  who-has-access summary.

## Update (self-update, the crux)

The package carries its own SessionStart updater, `hooks/agent-pack-update.sh`,
modeled on hq-core's `check-hq-update.sh`. On each **agent** session start it:

1. gates on agent-only (exits immediately otherwise);
2. **throttles** — 24h TTL cache in `workspace/.hq-pack-agent/last-check.json`
   (delete it to force a re-check);
3. **resolves auth** for the private repo — an hq-vault deploy token
   (`HQ_PACK_AGENT_DEPLOY_TOKEN`) via the `hq` CLI, else `GH_TOKEN`/`GITHUB_TOKEN`,
   else an authenticated `gh`. None available → silent no-op;
4. **compares** the installed `VERSION` to the latest GitHub Release tag (semver);
5. if newer, spawns a **fully detached** background updater (`install/do-update.sh`)
   that backs up the current tree to `workspace/.hq-pack-agent/prev/`, pulls the
   release, re-runs `install.sh`, and **rolls back** to the prior version if the
   new `install.sh` exits non-zero. The update applies to the **next** session,
   never the current one;
6. **always exits 0.** Advisory infra — every failure is silent and logged only
   to the package-local `workspace/.hq-pack-agent/debug.log`. **A token is never
   printed to stdout or the log** (tokens travel via env/headers only, and the
   log is scrubbed).

Because the updater ships inside the package and is re-installed on every update,
the package upgrades its own update logic over time.

### Cutting a release

```bash
# bump VERSION, package.yaml version, and plugin.json version together
bash scripts/build-plugin.sh                 # validates version parity, builds a tarball
git tag vX.Y.Z && gh release create vX.Y.Z -R indigoai-us/hq-pack-agent
```

## Remove

```bash
bash install/uninstall.sh
```

`uninstall.sh` is the exact inverse of `install.sh`: it strips the package's hook
entries from `.claude/settings.local.json` (identified by the gate-path marker),
restores the recorded pre-install settings **byte-identical** when nothing else
changed (or surgically preserves unrelated user edits), and removes the
package-owned `workspace/.hq-pack-agent/` state dir. The host HQ is left
byte-identical to its pre-install state.

## `/new-agent` integration

New agents self-install the package by running `install/bootstrap.sh` (in
provisioning mode) as a step in `/new-agent`, after identity + vault are set up
so the deploy-token secret resolves. See `docs/new-agent-integration.md`.

## Layout

```
hq-pack-agent/
  .claude-plugin/{plugin.json,marketplace.json}
  package.yaml          # canonical version + metadata
  VERSION               # single source the updater diffs against
  README.md
  install/
    bootstrap.sh        # entrypoint: clone/pull private repo -> install.sh
    install.sh          # idempotent installer (local overlay, never core)
    uninstall.sh        # exact, byte-identical inverse
    do-update.sh        # detached updater with backup + rollback
    lib/is-agent.sh     # THE shared agent-detection gate
  hooks/
    agent-pack-gate.sh      # package's own agent-only hook gate
    agent-pack-update.sh    # SELF-UPDATE SessionStart hook
    agent-pack-policies.sh  # injects the agent policy pack (SessionStart)
    agent-slack-guard.sh    # markdown-strip / short-reply guidance
    agent-plan-clarify.sh   # plan-mode / clarify gate
    agent-company-file-access.sh # company-file access awareness (channel cross-ref)
    agent-slack-context.sh  # Slack session context (sender + channel roster)
    agent-learn-handoff.sh  # forced learning + handoff
    lib/{common.sh,markdown-strip.sh,slack-context.sh,is-agent.sh}
  policies/             # agent-only policy .md files (injected, not core-loaded)
  skills/               # agent-facing skills (deferred in v1 — see skills/README.md)
  scripts/build-plugin.sh
  tests/run.sh          # hermetic suite (agent-gate, updater, rollback, idempotency, uninstall, transform)
  docs/new-agent-integration.md
```

## Tests

```bash
bash tests/run.sh
```

Hermetic (temp HQ root, stubbed `gh`/`hq`/`git`, no network). Covers the
agent-gate (inert for humans / active for agents), updater version decisions +
TTL throttle + cache-delete, auth-missing silent no-op with a no-token-leak
assertion, rollback on a failing release, install idempotency, byte-identical
uninstall (both fresh-host and pre-existing-settings cases), and the
markdown-strip transform.
```
