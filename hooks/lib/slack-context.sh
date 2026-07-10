#!/bin/bash
# slack-context.sh — read the Slack session context hq-pro passes in AT SPAWN.
#
# This is the integration contract between hq-pro (the spawner) and hq-pack-agent
# (the reader). hq-pro resolves the triggering Slack message's sender + the
# channel roster (with emails) once, at spawn, and hands it to the agent session.
#
# Source precedence (first that yields context wins):
#   1. $HQ_SLACK_CONTEXT_FILE — an explicit, per-session JSON file. STRONGLY
#      preferred: hq-pro should point this at a session-unique path so concurrent
#      agent sessions never read each other's roster.
#   2. Per-process env vars (fresh per spawn): HQ_SLACK_CHANNEL_ID,
#      HQ_SLACK_CHANNEL_NAME, HQ_SLACK_SENDER_EMAIL, HQ_SLACK_SENDER_HANDLE,
#      HQ_SLACK_MEMBER_EMAILS (comma/space separated).
#   3. The shared default file <hq-root>/workspace/.hq-pack-agent/slack-context.json
#      — LAST resort only (a persistent shared file can be overwritten by a later
#      spawn; env is preferred over it for exactly that reason).
#
# JSON schema:
#   { "channel": { "id": "C123", "name": "acme-deals" },
#     "sender":  { "email": "jacob@corp.com", "slack_id": "U1", "handle": "jacob" },
#     "members": [ { "email": "a@corp.com" }, ... ] }
#
# The roster emitted downstream is the deduplicated union of members[].email AND
# sender.email — the sender is always part of the channel audience even if hq-pro
# omits them from members[].
#
# The hook never calls Slack itself. Sourced AFTER common.sh. python3 for robust
# JSON; graceful no-op if context is absent/malformed or python3 is missing.

HQPA_SLACK_PY=''
IFS= read -r -d '' HQPA_SLACK_PY <<'PY' || true
import os, json

def norm(v):
    return v.strip().lower() if isinstance(v, str) else ""

def load_file(path):
    if path and os.path.isfile(path):
        try:
            d = json.load(open(path, encoding="utf-8"))
            return d if isinstance(d, dict) else None
        except Exception:
            return None
    return None

ctx = None
# (1) explicit per-session file
ctx = load_file(os.environ.get("HQ_SLACK_CONTEXT_FILE", ""))
source = "explicit-file" if ctx is not None else None

# (2) per-process env vars (only if no explicit file)
if ctx is None:
    env_keys = ("HQ_SLACK_CHANNEL_ID", "HQ_SLACK_CHANNEL_NAME", "HQ_SLACK_SENDER_EMAIL",
                "HQ_SLACK_SENDER_HANDLE", "HQ_SLACK_MEMBER_EMAILS")
    if any(os.environ.get(k) for k in env_keys):
        raw = os.environ.get("HQ_SLACK_MEMBER_EMAILS", "")
        ctx = {
            "channel": {"id": os.environ.get("HQ_SLACK_CHANNEL_ID", ""),
                        "name": os.environ.get("HQ_SLACK_CHANNEL_NAME", "")},
            "sender": {"email": os.environ.get("HQ_SLACK_SENDER_EMAIL", ""),
                       "handle": os.environ.get("HQ_SLACK_SENDER_HANDLE", "")},
            "members": [{"email": e} for e in raw.replace(",", " ").split()],
        }
        source = "env"

# (3) shared default file (last resort)
if ctx is None:
    ctx = load_file(os.environ.get("HQPA_SLACK_CTX_DEFAULT", ""))
    source = "default-file" if ctx is not None else None

if ctx is None:
    raise SystemExit  # no context -> emit nothing

# Build the FULL normalized result in memory, THEN emit atomically. A malformed
# member is skipped (never raises mid-emit), so partial output can't be mistaken
# for a complete roster.
ch = ctx.get("channel") or {}
sd = ctx.get("sender") or {}
lines = []
lines.append(("CHANNEL_ID", ch.get("id", "") if isinstance(ch.get("id"), str) else ""))
lines.append(("CHANNEL_NAME", ch.get("name", "") if isinstance(ch.get("name"), str) else ""))
sender_email = norm(sd.get("email"))
lines.append(("SENDER_EMAIL", sender_email))
lines.append(("SENDER_HANDLE", sd.get("handle", "") if isinstance(sd.get("handle"), str) else ""))

emails = []
seen = set()
def add(e):
    e = norm(e)
    if e and e not in seen:
        seen.add(e); emails.append(e)

for m in (ctx.get("members") or []):
    if isinstance(m, dict):
        add(m.get("email"))
# sender is always part of the channel audience
add(sender_email)

for e in emails:
    lines.append(("MEMBER", e))

out = "".join("%s\t%s\n" % (k, v) for k, v in lines if v)
import sys
sys.stdout.write(out)
PY

hqpa_slack_default_ctx_file() {
  local d; d="$(hqpa_state_dir 2>/dev/null)"
  [ -n "$d" ] && printf '%s/slack-context.json' "$d" || printf ''
}

hqpa_slack_dump() {
  command -v python3 >/dev/null 2>&1 || return 0
  HQPA_SLACK_CTX_DEFAULT="$(hqpa_slack_default_ctx_file)" python3 -c "$HQPA_SLACK_PY" 2>/dev/null
}

hqpa_slack_present() {
  [ -n "$(hqpa_slack_dump)" ]
}
