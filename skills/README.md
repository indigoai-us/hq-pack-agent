# skills/ — agent-facing skills (deferred in v1)

This directory is the home for any agent-only skills the package provides.

**Why v1 ships none by default.** Claude Code skill discovery is a static,
global filesystem scan (`.claude/skills/`), shared by every session on the box.
Symlinking a skill there would make it visible to human sessions too, breaking
the package's hard "agent-only / human-inert" guarantee. Until an agent-scoped
skill-exposure mechanism exists, v1 delivers its behavior payload entirely as
agent-gated **hooks + policies** (which are provably inert for humans because
every hook routes through `agent-pack-gate.sh`).

**How to add one later.** Drop `skills/<name>/SKILL.md` here, then have
`install/install.sh` wire it only through an agent-gated path (e.g. a
`.claude/settings.local.json`-driven surface, or an agent-only skills root that
the runtime consults only when `is-agent` is true). Do **not** symlink it into
the global `.claude/skills/` — that would leak it to humans.
