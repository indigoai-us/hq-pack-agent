#!/bin/bash
# slack-context.sh — read the Slack session context hq-pro passes in AT SPAWN.
#
# This is the integration contract between hq-pro (the spawner) and hq-pack-agent
# (the reader). hq-pro resolves the triggering Slack message's sender + the
# channel roster (with emails) once, at spawn, and hands it to the agent session
# in ONE of these forms (checked in order):
#
#   1. A JSON file at   $HQ_SLACK_CONTEXT_FILE
#      or (default)     <hq-root>/workspace/.hq-pack-agent/slack-context.json
#      Schema:
#        {
#          "channel": { "id": "C123", "name": "acme-deals" },
#          "sender":  { "email": "jacob@corp.com", "slack_id": "U1", "handle": "jacob" },
#          "members": [ { "email": "a@corp.com", "slack_id": "U2", "handle": "a" }, ... ]
#        }
#   2. Env fallback: HQ_SLACK_CHANNEL_ID, HQ_SLACK_CHANNEL_NAME,
#      HQ_SLACK_SENDER_EMAIL, HQ_SLACK_SENDER_HANDLE,
#      HQ_SLACK_MEMBER_EMAILS (comma/space separated).
#
# The hook never calls Slack itself — the roster is "passed in at spawn".
#
# Sourced AFTER common.sh (uses hqpa_state_dir). Pure library: defines a normalized
# dumper + accessors, no output on source. python3 for robust JSON; graceful
# no-op if the context is absent or python3 is missing.

# The dumper program, slurped once at source time (NOT inside $() — bash-3.2 trap).
HQPA_SLACK_PY=''
IFS= read -r -d '' HQPA_SLACK_PY <<'PY' || true
import os, json, sys

def emit(k, v):
    if v:
        print(f"{k}\t{v}")

ctx = None
path = os.environ.get("HQ_SLACK_CONTEXT_FILE") or os.environ.get("HQPA_SLACK_CTX_DEFAULT", "")
if path and os.path.isfile(path):
    try:
        ctx = json.load(open(path, encoding="utf-8"))
    except Exception:
        ctx = None

if isinstance(ctx, dict):
    ch = ctx.get("channel") or {}
    sd = ctx.get("sender") or {}
    emit("CHANNEL_ID", ch.get("id", ""))
    emit("CHANNEL_NAME", ch.get("name", ""))
    emit("SENDER_EMAIL", (sd.get("email") or "").strip().lower())
    emit("SENDER_HANDLE", sd.get("handle", ""))
    for m in (ctx.get("members") or []):
        if isinstance(m, dict):
            e = (m.get("email") or "").strip().lower()
            if e:
                emit("MEMBER", e)
else:
    # Env fallback.
    emit("CHANNEL_ID", os.environ.get("HQ_SLACK_CHANNEL_ID", ""))
    emit("CHANNEL_NAME", os.environ.get("HQ_SLACK_CHANNEL_NAME", ""))
    emit("SENDER_EMAIL", os.environ.get("HQ_SLACK_SENDER_EMAIL", "").strip().lower())
    emit("SENDER_HANDLE", os.environ.get("HQ_SLACK_SENDER_HANDLE", ""))
    raw = os.environ.get("HQ_SLACK_MEMBER_EMAILS", "")
    for e in raw.replace(",", " ").split():
        e = e.strip().lower()
        if e:
            emit("MEMBER", e)
PY

# hqpa_slack_default_ctx_file — the default JSON path under the state dir.
hqpa_slack_default_ctx_file() {
  local d; d="$(hqpa_state_dir 2>/dev/null)"
  [ -n "$d" ] && printf '%s/slack-context.json' "$d" || printf ''
}

# hqpa_slack_dump — emit normalized "KEY<TAB>value" lines (see HQPA_SLACK_PY).
# Empty output ⇒ no Slack context available.
hqpa_slack_dump() {
  command -v python3 >/dev/null 2>&1 || return 0
  HQPA_SLACK_CTX_DEFAULT="$(hqpa_slack_default_ctx_file)" python3 -c "$HQPA_SLACK_PY" 2>/dev/null
}

# hqpa_slack_present — 0 if any Slack context is available, else 1.
hqpa_slack_present() {
  [ -n "$(hqpa_slack_dump)" ]
}
