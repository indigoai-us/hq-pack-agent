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
# ACCESS MODEL — mirrors hq-pro resolveEffectivePermission (most-specific-match):
# the single MOST-SPECIFIC ACL that covers the file wins, and ONLY that ACL's
# grantees have access. Grants on less-specific ancestor prefixes are SHADOWED
# when a more-specific ACL exists. We therefore compute access from the winning
# ACL layer only (never a naive union of Direct + Inherited), and we bias toward
# NOT claiming access when unsure — a false "has access" could leak data, a false
# "no access" only over-warns.
#
# The ACL is fetched live via `hq files acl`; company-wide / open grants are
# resolved against `hq members list`. Both are cached per session, time-boxed,
# key-verified, and only cached on a SUCCESSFUL, well-formed fetch. Advisory only
# (adds context, never blocks). Agent-only; silent no-op for non-company paths,
# human sessions, or when hq/python are unavailable.

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

# Robust file_path extraction via JSON (not a line regex) — handles pretty-printed
# JSON and escaped characters correctly.
FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
ti=d.get("tool_input") or {}
fp=ti.get("file_path")
print(fp if isinstance(fp,str) else "")' 2>/dev/null)"
[ -n "$FILE" ] || exit 0

# Must be a companies/<slug>/... path (literal slash-delimited component).
case "$FILE" in
  */companies/*|companies/*) ;;
  *) exit 0 ;;
esac
SLUG="$(printf '%s' "$FILE" | sed -nE 's#.*companies/([^/]+)/.*#\1#p')"
REL="$(printf '%s'  "$FILE" | sed -nE 's#.*companies/[^/]+/(.*)#\1#p')"
[ -n "$SLUG" ] && [ -n "$REL" ] || exit 0

STATE_DIR="$(hqpa_state_dir)"; [ -n "$STATE_DIR" ] || exit 0
CACHE="$STATE_DIR/acl-cache"; mkdir -p "$CACHE" 2>/dev/null || true

_hqpa_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# Collision-resistant cache key hash (sha256 with portable fallbacks).
_hqpa_hash() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else printf '%s' "$1" | cksum | awk '{print $1"-"$2}'; fi
}

# Cached fetch, fail-CLOSED: caches ONLY a successful (exit 0), non-empty,
# structurally-valid result, and verifies the stored key on read (guards against
# hash aliasing). $1=key $2=ttl $3=validator-regex ; rest = command.
_hqpa_cached() {
  local key="$1" ttl="$2" valid="$3"; shift 3
  local cf; cf="$CACHE/$(_hqpa_hash "$key").txt"
  if [ -f "$cf" ]; then
    local mt now; mt=$(stat -c %Y "$cf" 2>/dev/null || stat -f %m "$cf" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ "$((now - mt))" -lt "$ttl" ]; then
      # First line is the stored key; verify before trusting the body.
      if [ "$(head -1 "$cf" 2>/dev/null)" = "HQPA-KEY:$key" ]; then
        tail -n +2 "$cf" 2>/dev/null; return 0
      fi
    fi
  fi
  local out status
  out="$("$@" 2>/dev/null)"; status=$?
  if [ "$status" -eq 0 ] && [ -n "$out" ] && printf '%s' "$out" | grep -qE "$valid"; then
    { printf 'HQPA-KEY:%s\n' "$key"; printf '%s' "$out"; } > "$cf" 2>/dev/null
    printf '%s' "$out"; return 0
  fi
  # Failed / empty / malformed — do NOT cache, return nothing (fail-closed).
  printf ''
  return 1
}

ACL_TEXT="$(_hqpa_cached "acl:$SLUG:$REL" 180 '^ACL for ' _hqpa_to 8 hq files acl "$REL" --company "$SLUG")"
MEMBERS_TEXT="$(_hqpa_cached "members:$SLUG" 600 '@' _hqpa_to 8 hq members list --company "$SLUG")"

DUMP="$(hqpa_slack_dump)"
ROSTER="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="MEMBER"{print $2}')"
CHANNEL_NAME="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="CHANNEL_NAME"{print $2; exit}')"
CHANNEL_ID="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1=="CHANNEL_ID"{print $2; exit}')"
CHANNEL_LABEL="${CHANNEL_NAME:+#$CHANNEL_NAME}"; [ -n "$CHANNEL_LABEL" ] || CHANNEL_LABEL="${CHANNEL_ID}"

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

def esc_attr(s):
    return s.replace('"', "'")

# ── company members (human email rows from `hq members list`) ──
company_members = set()
for line in members_raw.splitlines():
    tok = line.split()
    if tok and "@" in tok[0]:
        company_members.add(tok[0].strip().lower())

# ── parse ACL rows, right-anchored so multi-word "Everyone in company" is safe ──
# Section = keep {Direct, Inherited}; ignore {Descendant}. Each kept row carries a
# source prefix: Direct rows implicitly target REL (most specific); Inherited rows
# carry an explicit SOURCE column.
def specificity(src):
    s = src.rstrip("/")
    glob = 1 if s.endswith("/*") else 0
    base = s[:-2] if glob else s
    return (base.count("/"), 0 if glob else 1)   # deeper wins; exact beats glob

rows = []                 # (source, type, grantee)
section = None
acl_open = "(open)" in acl or "Open ACL" in acl.lower() or "all active members have read" in acl.lower()
for line in acl.splitlines():
    s = line.strip()
    ls = s.lower()
    if ls.startswith("direct entries"):        section = "direct"; continue
    if ls.startswith("inherited"):             section = "inherited"; continue
    if ls.startswith("granted on descendant"): section = "skip"; continue
    if section not in ("direct", "inherited") or not s: continue
    if s.startswith("TYPE"):                    continue
    tok = s.split()
    t = tok[0].lower()
    if t not in ("email", "person", "group", "company-wide"): continue
    if section == "direct":
        # TYPE GRANTEE.. PERMISSION GRANTED_BY GRANTED_AT   (>=5 cols)
        if len(tok) < 5: continue
        grantee = " ".join(tok[1:-3]); src = rel
    else:
        # TYPE GRANTEE.. PERMISSION GRANTED_BY SOURCE GRANTED_AT   (>=6 cols)
        if len(tok) < 6: continue
        grantee = " ".join(tok[1:-4]); src = tok[-2]
    rows.append((src, t, grantee.strip()))

# ── winner = single most-specific ACL layer (by source prefix) ──
winner_email, winner_company_wide, n_person, n_group = set(), False, 0, 0
if rows:
    best = max(specificity(src) for src, _, _ in rows)
    for src, t, grantee in rows:
        if specificity(src) != best:
            continue                      # shadowed by a more-specific ACL
        if t == "email":            winner_email.add(grantee.lower())
        elif t == "company-wide":   winner_company_wide = True
        elif t == "person":         n_person += 1
        elif t == "group":          n_group += 1

# An open ACL floors access at read for all active company members.
if acl_open:
    winner_company_wide = True

# ── confident access-email set (winner layer only) ──
access = set(winner_email)
if winner_company_wide:
    access |= company_members

def caveat():
    bits = []
    if n_person: bits.append("%d person grant(s)" % n_person)
    if n_group:  bits.append("%d group grant(s)" % n_group)
    extra = (" — plus " + " and ".join(bits) + " not resolved to emails") if bits else ""
    return ("This access list is NOT exhaustive%s, and access is approximated from the "
            "most-specific ACL. For the authoritative, complete ACL run:\n"
            "  hq files acl '%s' --company %s") % (extra, rel, slug)

if not acl.strip():
    print('<hq-pack-agent-file-access file="%s">' % esc_attr(fileref))
    print("Could not resolve the access list for this company file right now.")
    print("Treat it as sensitive: before sharing its contents anywhere, check it yourself:")
    print("  hq files acl '%s' --company %s" % (rel, slug))
    print("</hq-pack-agent-file-access>")
    raise SystemExit

hdr = '<hq-pack-agent-file-access file="%s"%s>' % (esc_attr(fileref), (' channel="%s"' % esc_attr(chan)) if chan else "")
print(hdr)

if roster:
    seen, uniq = set(), []
    for m in roster:
        if m not in seen:
            seen.add(m); uniq.append(m)
    with_access = [m for m in uniq if m in access]
    without = [m for m in uniq if m not in access]
    print("Access for this company file, cross-referenced against %s:" % (chan or "the current channel"))
    print("")
    if with_access:
        print("Channel members WITH access (safe to discuss this file with them):")
        for m in with_access: print("  - " + m)
    else:
        print("Channel members WITH access: none of the current channel members could be confirmed.")
    print("")
    if without:
        print("Channel members WITHOUT confirmed access to this file:")
        for m in without: print("  - " + m)
        print("")
        print("⚠ DO NOT share the contents of this file in %s — %d channel member(s) above are not confirmed to have access." % (chan or "this channel", len(without)))
    else:
        print("All current channel members appear to have access to this file.")
    print("")
else:
    print("Who can access this company file (most-specific ACL layer):")
    if winner_email:
        for m in sorted(winner_email): print("  - " + m)
    if winner_company_wide:
        print("  - everyone in company '%s' (company-wide/open read)" % slug)
    if not winner_email and not winner_company_wide:
        print("  (no direct email or company-wide grants at the winning layer; access is via person/group grants)")
    print("")

print(caveat())
print("</hq-pack-agent-file-access>")
PY

ACL_TEXT="$ACL_TEXT" MEMBERS_TEXT="$MEMBERS_TEXT" ROSTER="$ROSTER" \
FILEREF="$FILE" REL="$REL" SLUG="$SLUG" CHANNEL_LABEL="$CHANNEL_LABEL" \
python3 -c "$PYPROG"
} 2>/dev/null || true
exit 0
