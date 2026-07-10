#!/bin/bash
# is-agent.sh — the ONE shared agent-detection gate for hq-pack-agent.
#
# Sourced by every package hook. Defines hq_is_agent_session(): returns 0 (true)
# ONLY for a genuine HQ agent session (an autonomous Slack / email / cloud
# worker), 1 (false) for everything else — including every human HQ session.
#
# Detection is EXPLICIT, never heuristic. We look at runtime identity markers set
# by the agent runtimes (never at cwd, hostname, or "does this look like a bot").
# If the signal is ambiguous or absent, we DEFAULT TO NOT-AN-AGENT so the package
# stays inert rather than leaking agent behavior into a human session.
#
# Precedence (first decisive signal wins):
#   1. HQ_PACK_AGENT_FORCE_HUMAN truthy  -> NOT an agent   (hard override, tests/safety)
#   2. HQ_PACK_AGENT_FORCE_AGENT truthy  -> IS an agent    (hard override, tests/provisioning)
#   3. Any positive runtime marker below -> IS an agent
#   4. otherwise                         -> NOT an agent   (safe default)
#
# This file is pure library: sourcing it defines the function and does nothing
# else (no output, no exit). Safe to source from a trap-exit-0 hook.

# _hqpa_truthy VALUE -> 0 if VALUE looks truthy (1/true/yes/on), else 1
_hqpa_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on|y) return 0 ;;
    *) return 1 ;;
  esac
}

hq_is_agent_session() {
  # (1) Hard human override — always wins. Lets a human force the package inert,
  # and lets tests assert the "human session" branch deterministically.
  if _hqpa_truthy "${HQ_PACK_AGENT_FORCE_HUMAN:-}"; then
    return 1
  fi

  # (2) Hard agent override — explicit opt-in from provisioning / tests.
  if _hqpa_truthy "${HQ_PACK_AGENT_FORCE_AGENT:-}"; then
    return 0
  fi

  # (3) Positive runtime markers. ANY one of these means "genuine agent session".
  #
  # (3a) Explicit agent-session env flags set by HQ agent runtimes.
  if _hqpa_truthy "${HQ_AGENT_SESSION:-}" || _hqpa_truthy "${HQ_IS_AGENT:-}"; then
    return 0
  fi

  # (3b) Agent/worker identity env vars. HQ agent runtimes (slack-bot worker
  # dispatch, /new-agent fleet workers, headless cloud runs) export the agent's
  # slug/identity. A human interactive session never sets these.
  for v in "${HQ_AGENT_SLUG:-}" "${HQ_WORKER_SLUG:-}" "${HQ_AGENT_ID:-}" \
           "${HQ_SLACK_BOT_SLUG:-}" "${HQ_AGENT_PERSON_UID:-}"; do
    [ -n "$v" ] && return 0
  done

  # (3c) Provisioned agent-identity marker file. /new-agent (or bootstrap.sh run
  # in provisioning mode) drops this into the agent's HQ. Its presence is a
  # durable, restart-surviving signal that this HQ install belongs to an agent.
  local root
  root="$(_hqpa_hq_root)"
  if [ -n "$root" ] && [ -f "$root/workspace/.hq-pack-agent/agent-identity.json" ]; then
    return 0
  fi

  # (4) Default: NOT an agent. Stay inert.
  return 1
}

# _hqpa_hq_root — best-effort HQ root, without assuming cwd.
#   Prefers CLAUDE_PROJECT_DIR (set by Claude Code), else walks up from this file
#   (install/lib/is-agent.sh -> HQ root is three levels up from install/lib when
#   the package is installed under the HQ tree; when sourced from the repo copy it
#   still yields a usable path via the env var). Empty string if undeterminable.
_hqpa_hq_root() {
  if [ -n "${HQ_PACK_AGENT_HQ_ROOT:-}" ]; then
    printf '%s' "$HQ_PACK_AGENT_HQ_ROOT"; return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"; return 0
  fi
  printf ''
}
