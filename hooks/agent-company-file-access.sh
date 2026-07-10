#!/bin/bash
# agent-company-file-access.sh — PreToolUse (Read). Company-file access awareness.
#
# When an agent is about to read a file under companies/<slug>/, tell it who can
# access that file — cross-referenced against the current Slack channel roster
# (passed in at spawn; see hooks/lib/slack-context.sh):
#   * which channel members DO have access (safe to discuss the file with them),
#   * which channel members do NOT have access (explicitly listed),
#   * a warning NOT to share the file's contents in the channel when any member
#     lacks access,
#   * a note that the cross-reference is NOT exhaustive, plus the exact `hq`
#     command to fetch the full authoritative ACL.
#
# The ACL is fetched live via the hq CLI (`hq files acl`); company-wide grants are
# resolved against `hq members list`. Both are cached per session and time-boxed.
# Advisory only (adds context, never blocks). Agent-only; silent no-op for
# non-company paths, human sessions, or when hq/python are unavailable.

trap 'exit 0' EXIT
INPUT="$(cat 2>/dev/null || true)"
{
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
. "$HOOK_DIR/lib/common.sh" 2>/dev/null || exit 0
. "$HOOK_DIR/lib/slack-context.sh" 2>/dev/null || exit 0
for c in "$HOOK_DIR/lib/is-agent.sh" "$HOOK_DIR/../install/lib/is-agent.sh"; do
  [ -f "$c" ] && { . "$c" 2>/dev/null; break; }
done
command -v hq_is_agent_session >/dev/null 2>&1 || exit 0
hq_is_agent_session || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v hq >/dev/null 2>&1 || exit 0

FILE="$(printf '%s' "$INPUT" | sed -nE 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -n "$FILE" ] || exit 0

# Must be a companies/<slug>/... path.
case "$FILE" in
  */companies/*|companies/*) ;;
  *) exit 0 ;;
esac
SLUG="$(printf '%s' "$FILE" | sed -nE 's#.*companies/([^/]+)/.*#\1#p')"
REL="$(printf '%s'  "$FILE" | sed -nE 's#.*companies/[^/]+/(.*)#\1#p')"
[ -n "$SLUG" ] && [ -n "$REL" ] || exit 0

STATE_DIR="$(hqpa_state_dir)"; [ -n "$STATE_DIR" ] || exit 0
CACHE="$STATE_DIR/acl-cache"; mkdir -p "$CACHE" 2>/dev/null || true

# Run a command with a hard timeout if `timeout`/`gtimeout` exists, else bare.
_hqpa_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}
# Cached fetch: $1=cache-key $2=ttl -- rest = command. Echoes output.
_hqpa_cached() {
  local key="$1" ttl="$2"; shift 2
  local cf; cf="$CACHE/$(printf '%s' "$key" | cksum | awk '{print $1}').txt"
  if [ -f "$cf" ]; then
    local mt now; mt=$(stat -c %Y "$cf" 2>/dev/null || stat -f %m "$cf" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ "$((now - mt))" -lt "$ttl" ]; then cat "$cf"; return 0; fi
  fi
  local out; out="$("$@" 2>/dev/null)"
  [ -n "$out" ] && printf '%s' "$out" > "$cf" 2>/dev/null
  printf '%s' "$out"
}

ACL_TEXT="$(_hqpa_cached "acl:$SLUG:$REL" 300 _hqpa_to 8 hq files acl "$REL" --company "$SLUG")"
MEMBERS_TEXT="$(_hqpa_cached "members:$SLUG" 600 _hqpa_to 8 hq members list --company "$SLUG")"

DUMP="$(hqpa_slack_dump)"
ROSTER="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="MEMBER"{print $2}')"
CHANNEL_NAME="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="CHANNEL_NAME"{print $2; exit}')"
CHANNEL_ID="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="CHANNEL_ID"{print $2; exit}')"
CHANNEL_LABEL="${CHANNEL_NAME:+#$CHANNEL_NAME}"; [ -n "$CHANNEL_LABEL" ] || CHANNEL_LABEL="${CHANNEL_ID}"

# Analyze + render in python (robust set logic + fixed-width ACL parsing).
PYPROG=''
IFS= read -r -d '' PYPROG <<'PY' || true
import os

acl = os.environ.get("ACL_TEXT", "")
members_raw = os.environ.get("MEMBERS_TEXT", "")
roster = [e for e in os.environ.get("ROSTER", "").split("\n") if e.strip()]
fileref = os.environ.get("FILEREF", "")
rel = os.environ.get("REL", "")
slug = os.environ.get("SLUG", "")
chan = os.environ.get("CHANNEL_LABEL", "").strip()

# Company member emails (human rows in `hq members list`).
company_members = set()
for line in members_raw.splitlines():
    tok = line.split()
    if tok and "@" in tok[0]:
        company_members.add(tok[0].strip().lower())

# Parse ACL: keep Direct + Inherited; ignore descendant-prefix grants.
email_grants, n_person, n_group, company_wide = set(), 0, 0, False
section = None
for line in acl.splitlines():
    s = line.strip()
    if s.startswith("Direct entries"):        section = "keep"; continue
    if s.startswith("Inherited"):             section = "keep"; continue
    if s.startswith("Granted on descendant"): section = "skip"; continue
    if section != "keep" or not s:            continue
    if s.startswith("TYPE"):                  continue          # header row
    toks = s.split()
    t = toks[0].lower()
    if t == "email" and len(toks) >= 2:       email_grants.add(toks[1].strip().lower())
    elif t == "person":                       n_person += 1
    elif t == "group":                        n_group += 1
    elif t == "company-wide":                 company_wide = True

# Effective confident access-email set.
access = set(email_grants)
if company_wide:
    access |= company_members

def caveat():
    bits = []
    if n_person: bits.append(f"{n_person} person grant(s)")
    if n_group:  bits.append(f"{n_group} group grant(s)")
    extra = (" — plus " + " and ".join(bits) + " not resolved to emails") if bits else ""
    return ("This access list is NOT exhaustive%s. For the authoritative, complete ACL run:\n"
            "  hq files acl '%s' --company %s") % (extra, rel, slug)

if not acl.strip():
    print("<hq-pack-agent-file-access file=\"%s\">" % fileref)
    print("Could not resolve the access list for this company file right now.")
    print("Before sharing its contents anywhere, check it yourself:")
    print("  hq files acl '%s' --company %s" % (rel, slug))
    print("</hq-pack-agent-file-access>")
    raise SystemExit

hdr = "<hq-pack-agent-file-access file=\"%s\"%s>" % (fileref, (" channel=\"%s\"" % chan) if chan else "")
print(hdr)

if roster:
    with_access = [m for m in roster if m in access]
    without = [m for m in roster if m not in access]
    print("Access for this company file, cross-referenced against %s:" % (chan or "the current channel"))
    print("")
    if with_access:
        print("Channel members WITH access (safe to discuss this file with them):")
        for m in with_access: print("  - " + m)
    else:
        print("Channel members WITH access: none of the current channel members could be confirmed.")
    print("")
    if without:
        print("Channel members WITHOUT access to this file:")
        for m in without: print("  - " + m)
        print("")
        print("⚠ DO NOT share the contents of this file in %s — %d channel member(s) above cannot access it." % (chan or "this channel", len(without)))
    else:
        print("All current channel members can access this file.")
    print("")
else:
    # No Slack roster — still surface who has access generally.
    print("Who can access this company file:")
    if email_grants:
        for m in sorted(email_grants): print("  - " + m)
    if company_wide:
        print("  - everyone in company '%s' (company-wide grant)" % slug)
    if not email_grants and not company_wide:
        print("  (no direct email or company-wide grants; access is via person/group grants)")
    print("")

print(caveat())
print("</hq-pack-agent-file-access>")
PY

ACL_TEXT="$ACL_TEXT" MEMBERS_TEXT="$MEMBERS_TEXT" ROSTER="$ROSTER" \
FILEREF="$FILE" REL="$REL" SLUG="$SLUG" CHANNEL_LABEL="$CHANNEL_LABEL" \
python3 -c "$PYPROG"
} 2>/dev/null || true
exit 0
