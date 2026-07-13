#!/usr/bin/env bash
# run.sh — hq-pack-agent test suite (no shortcuts; real regression coverage).
#
# Covers every acceptance requirement from the build spec:
#   * agent-gate: no-op for human sessions, active for agent sessions
#   * is-agent detection precedence (force flags, markers, default-inert)
#   * updater: local<remote triggers; equal/greater does not; TTL throttle;
#     cache-delete forces re-check
#   * auth: NO token still updates (public repo, unauthenticated); nothing-to-
#     fetch is a graceful no-op; a token (when present) never leaks to output/log
#   * rollback: a release whose install.sh fails rolls back to the prior version
#   * idempotency: install twice -> identical settings
#   * uninstall: full inverse, host byte-identical
#   * markdown-strip transform: input -> expected plain output
#
# Runs hermetically in a temp HQ root with stubbed gh/hq/git on PATH. No network,
# never touches the real host HQ.

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hqpa-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "expected to contain: $3 | got: $2";; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "expected NOT to contain: $3 | got: $2";; *) ok "$1";; esac; }
assert_eq()           { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3' got '$2'"; }
assert_file()         { [ -f "$1" ] && ok "$2" || bad "$2" "missing file: $1"; }
assert_nofile()       { [ ! -e "$1" ] && ok "$2" || bad "$2" "file should not exist: $1"; }

# --- fresh temp HQ root ---
new_root() {
  local r="$TMP/hq-$1"
  mkdir -p "$r/.claude" "$r/workspace"
  printf '%s' "$r"
}

# --- build a stub-bin dir; caller sets FAKE_* env before invoking targets ---
make_stubs() {
  local bin="$1"; mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "auth status") [ "${FAKE_GH_AUTH:-0}" = "1" ] && exit 0 || exit 1 ;;
  "auth token")  [ "${FAKE_GH_AUTH:-0}" = "1" ] && { echo "ghp_FAKEfaketoken000000000000000000000000"; exit 0; } || exit 1 ;;
  *"release view"*) [ -n "${FAKE_GH_TAG:-}" ] && { echo "$FAKE_GH_TAG"; exit 0; } || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin/hq" <<'EOF'
#!/bin/bash
if [ "$1" = "secrets" ] && [ "$2" = "get" ]; then
  [ -n "${FAKE_HQ_SECRET:-}" ] && { printf '%s\n' "$FAKE_HQ_SECRET"; exit 0; }
  exit 0
fi
exit 1
EOF
  # Hermetic curl: the updater's unauthenticated fallback hits GitHub's
  # releases/latest — stub it (mirrors the gh stub via FAKE_GH_TAG) so tests
  # never touch the network (a real fetch would find the actual latest release).
  cat > "$bin/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *"releases/latest"*) [ -n "${FAKE_GH_TAG:-}" ] && { printf '{"tag_name":"%s"}\n' "$FAKE_GH_TAG"; exit 0; } || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh" "$bin/hq" "$bin/curl"
}

echo "== is-agent detection =="
(
  . "$PKG/install/lib/is-agent.sh"
  out=""
  HQ_PACK_AGENT_FORCE_AGENT=1 hq_is_agent_session && out=agent || out=human
  assert_eq "force-agent -> agent" "$out" "agent"
  HQ_PACK_AGENT_FORCE_HUMAN=1 HQ_PACK_AGENT_FORCE_AGENT=1 hq_is_agent_session && out=agent || out=human
  assert_eq "force-human overrides force-agent" "$out" "human"
  ( unset HQ_PACK_AGENT_FORCE_AGENT HQ_PACK_AGENT_FORCE_HUMAN HQ_AGENT_SESSION HQ_AGENT_SLUG
    hq_is_agent_session ) && out=agent || out=human
  assert_eq "no signal -> default human (inert)" "$out" "human"
  ( HQ_AGENT_SLUG=slackbot hq_is_agent_session ) && out=agent || out=human
  assert_eq "agent-slug env -> agent" "$out" "agent"
)

echo "== agent-pack-gate: human no-op / agent active =="
DELEG="$TMP/deleg.sh"; printf '#!/bin/bash\ncat >/dev/null 2>&1\necho RAN_DELEGATE\n' > "$DELEG"; chmod +x "$DELEG"
out_h="$(echo '{}' | HQ_PACK_AGENT_FORCE_HUMAN=1 bash "$PKG/hooks/agent-pack-gate.sh" demo "$DELEG" 2>/dev/null)"
assert_not_contains "gate: human session does not run delegate" "$out_h" "RAN_DELEGATE"
out_a="$(echo '{}' | HQ_PACK_AGENT_FORCE_AGENT=1 bash "$PKG/hooks/agent-pack-gate.sh" demo "$DELEG" 2>/dev/null)"
assert_contains "gate: agent session runs delegate" "$out_a" "RAN_DELEGATE"
out_d="$(echo '{}' | HQ_PACK_AGENT_FORCE_AGENT=1 HQ_PACK_AGENT_DISABLED_HOOKS=demo bash "$PKG/hooks/agent-pack-gate.sh" demo "$DELEG" 2>/dev/null)"
assert_not_contains "gate: disabled hook is skipped" "$out_d" "RAN_DELEGATE"

echo "== markdown-strip transform =="
. "$PKG/hooks/lib/markdown-strip.sh"
IN=$'# Heading\nThis is **bold** and `code` and _em_.\nSee [docs](https://x.io)\n```bash\nls\n```'
STRIP="$(printf '%s' "$IN" | hqpa_markdown_strip)"
assert_not_contains "strip removes bold markers" "$STRIP" "**"
assert_not_contains "strip removes backticks" "$STRIP" '`'
assert_not_contains "strip removes heading hashes" "$STRIP" "# Heading"
assert_contains "strip keeps heading words" "$STRIP" "Heading"
assert_contains "strip converts link to text (url)" "$STRIP" "docs (https://x.io)"
STRIP2="$(printf '%s' "$STRIP" | hqpa_markdown_strip)"
assert_eq "strip is idempotent" "$STRIP2" "$STRIP"

echo "== updater: auth resolution + version decisions =="
R1="$(new_root updater)"; BIN="$TMP/bin-updater"; make_stubs "$BIN"
mkdir -p "$R1/workspace/.hq-pack-agent"; printf '0.1.0\n' > "$R1/workspace/.hq-pack-agent/installed-version"
run_updater() { # env-configured; returns stdout. stdin from /dev/null so the
                # hook's `cat` sees EOF immediately (in production the master-hook
                # closes stdin; a test pipe would otherwise block it).
  ( export PATH="$BIN:$PATH" HQ_PACK_AGENT_HQ_ROOT="$R1" HQ_PACK_AGENT_FORCE_AGENT=1
    unset GH_TOKEN GITHUB_TOKEN
    "$@" bash "$PKG/hooks/agent-pack-update.sh" </dev/null 2>/dev/null )
}
# (a) TOKENLESS PUBLIC UPDATE: no token resolves, but the repo is PUBLIC, so a
# newer release is still fetched UNAUTHENTICATED and triggers the update. This is
# the crux of the tokenless relaxation.
printf '#!/bin/bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"   # detached child no-ops
rm -f "$R1/workspace/.hq-pack-agent/last-check.json" "$R1/workspace/.hq-pack-agent/update.stamp"
out="$(FAKE_GH_AUTH=0 FAKE_HQ_SECRET= FAKE_GH_TAG=v9.9.9 run_updater env)"; rc=$?
assert_eq "updater tokenless-public exits 0" "$rc" "0"
assert_contains "updater tokenless-public: newer public release triggers (banner)" "$out" "hq-pack-agent-update"
assert_file "$R1/workspace/.hq-pack-agent/update.stamp" "updater tokenless-public: writes cooldown stamp"
assert_not_contains "no token leaks to updater stdout" "$out" "faketoken"
assert_not_contains "no token leaks to debug log" "$(cat "$R1/workspace/.hq-pack-agent/debug.log" 2>/dev/null)" "faketoken"
# (a2) no token AND nothing resolvable (public fetch yields no tag) -> graceful no-op
rm -f "$R1/workspace/.hq-pack-agent/last-check.json" "$R1/workspace/.hq-pack-agent/update.stamp"
out="$(FAKE_GH_AUTH=0 FAKE_HQ_SECRET= run_updater env)"; rc=$?
assert_eq "updater no-tag exits 0" "$rc" "0"
assert_not_contains "updater no-tag: no banner when nothing resolves" "$out" "hq-pack-agent-update"
# (b) auth + equal version -> no update
rm -f "$R1/workspace/.hq-pack-agent/last-check.json" "$R1/workspace/.hq-pack-agent/update.stamp"
out="$(FAKE_GH_AUTH=1 FAKE_GH_TAG=v0.1.0 run_updater env)"
assert_not_contains "updater equal-version: no banner" "$out" "hq-pack-agent-update"
assert_nofile "$R1/workspace/.hq-pack-agent/update.stamp" "updater equal-version: no update stamp"
# (c) auth + newer version -> triggers (banner + cooldown stamp)
rm -f "$R1/workspace/.hq-pack-agent/last-check.json" "$R1/workspace/.hq-pack-agent/update.stamp"
# git stub so the detached updater child does nothing real
printf '#!/bin/bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"
out="$(FAKE_GH_AUTH=1 FAKE_GH_TAG=v9.9.9 run_updater env)"
assert_contains "updater newer-version: emits banner" "$out" "hq-pack-agent-update"
assert_file "$R1/workspace/.hq-pack-agent/update.stamp" "updater newer-version: writes cooldown stamp"
# (d) TTL throttle: fresh cache -> no work
printf '{"latest":"9.9.9"}' > "$R1/workspace/.hq-pack-agent/last-check.json"
rm -f "$R1/workspace/.hq-pack-agent/update.stamp"
out="$(FAKE_GH_AUTH=1 FAKE_GH_TAG=v9.9.9 run_updater env)"
assert_not_contains "updater TTL throttle: no banner when cache fresh" "$out" "hq-pack-agent-update"
assert_nofile "$R1/workspace/.hq-pack-agent/update.stamp" "updater TTL throttle: no work when cache fresh"
# (e) cache-delete forces re-check
rm -f "$R1/workspace/.hq-pack-agent/last-check.json"
FAKE_GH_AUTH=1 FAKE_GH_TAG=v0.1.0 run_updater env >/dev/null 2>&1
assert_file "$R1/workspace/.hq-pack-agent/last-check.json" "updater: cache re-created after delete"

echo "== do-update rollback =="
R2="$(new_root rollback)"; ST="$R2/workspace/.hq-pack-agent"; mkdir -p "$ST/repo/install"
printf '0.1.0\n' > "$ST/installed-version"
# GOOD install.sh (currently checked out): records that GOOD ran, exit 0
cat > "$ST/repo/install/install.sh" <<'EOF'
#!/bin/bash
echo GOOD > "$HQ_PACK_AGENT_HQ_ROOT/workspace/.hq-pack-agent/which-install"
exit 0
EOF
mkdir -p "$ST/repo/.git"
BIN2="$TMP/bin-rollback"; mkdir -p "$BIN2"
# git stub: on checkout/reset, simulate pulling a BAD release (install.sh fails)
cat > "$BIN2/git" <<'EOF'
#!/bin/bash
if [ "$1" = "-C" ]; then D="$2"; SUB="$3"; else SUB="$1"; D=""; fi
case "$SUB" in
  checkout|reset) [ -n "$D" ] && { mkdir -p "$D/install"; printf '#!/bin/bash\nexit 1\n' > "$D/install/install.sh"; }; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN2/git"
( export PATH="$BIN2:$PATH"
  HQ_PACK_AGENT_HQ_ROOT="$R2" HQ_PACK_AGENT_RELEASE_REPO="indigoai-us/hq-pack-agent" \
  HQ_PACK_AGENT_UPDATE_TOKEN="ghp_FAKEfaketoken0000000000000000000000" \
  bash "$PKG/install/do-update.sh" 9.9.9 >/dev/null 2>&1 )
assert_eq "rollback: GOOD (prior) install.sh ran after bad release" "$(cat "$ST/which-install" 2>/dev/null)" "GOOD"
assert_not_contains "rollback: no token in debug log" "$(cat "$ST/debug.log" 2>/dev/null)" "faketoken"

echo "== install idempotency + uninstall byte-identical (fresh host) =="
R3="$(new_root fresh)"
assert_nofile "$R3/.claude/settings.local.json" "precondition: no settings.local.json"
HQ_PACK_AGENT_HQ_ROOT="$R3" bash "$PKG/install/install.sh" >/dev/null 2>&1
assert_file "$R3/.claude/settings.local.json" "install: creates settings.local.json"
FIRST="$(cat "$R3/.claude/settings.local.json")"
HQ_PACK_AGENT_HQ_ROOT="$R3" bash "$PKG/install/install.sh" >/dev/null 2>&1
SECOND="$(cat "$R3/.claude/settings.local.json")"
assert_eq "install is idempotent (identical settings twice)" "$SECOND" "$FIRST"
assert_contains "install wired the gate into settings" "$FIRST" "agent-pack-gate.sh"
HQ_PACK_AGENT_HQ_ROOT="$R3" bash "$PKG/install/uninstall.sh" >/dev/null 2>&1
assert_nofile "$R3/.claude/settings.local.json" "uninstall: removes settings.local.json (byte-identical absence)"
assert_nofile "$R3/workspace/.hq-pack-agent" "uninstall: removes package state dir"

echo "== uninstall preserves pre-existing user settings (byte-identical) =="
R4="$(new_root preexisting)"
printf '{\n  "env": {\n    "FOO": "bar"\n  }\n}\n' > "$R4/.claude/settings.local.json"
ORIG="$(cat "$R4/.claude/settings.local.json")"
HQ_PACK_AGENT_HQ_ROOT="$R4" bash "$PKG/install/install.sh" >/dev/null 2>&1
assert_contains "install: user's pre-existing key survives" "$(cat "$R4/.claude/settings.local.json")" "\"FOO\""
HQ_PACK_AGENT_HQ_ROOT="$R4" bash "$PKG/install/uninstall.sh" >/dev/null 2>&1
assert_eq "uninstall: restores pre-existing settings byte-identical" "$(cat "$R4/.claude/settings.local.json")" "$ORIG"

echo "== slack-context: sender + roster, precedence, sender-union, dedup =="
SBIN="$TMP/bin-slack"; mkdir -p "$SBIN"
cat > "$SBIN/hq" <<'HQ'
#!/bin/bash
if [ "$1" = "files" ] && [ "$2" = "acl" ]; then
  case "${ACL_MODE:-direct-shadow}" in
    fail) exit 1 ;;
    empty) exit 0 ;;
    direct-shadow)
cat <<'A'
ACL for knowledge/x.md (restricted)
Direct entries (granted on this prefix):
TYPE    GRANTEE         PERMISSION  GRANTED_BY  GRANTED_AT
email   jacob@corp.com  read        prs_X       2026-07-10
Inherited (granted on an ancestor prefix):
TYPE    GRANTEE         PERMISSION  GRANTED_BY  SOURCE       GRANTED_AT
email   corey@corp.com  read        prs_X       knowledge/*  2026-05-20
company-wide  Everyone in company  read  prs_X  knowledge/*  2026-06-01
Granted on descendant prefixes (do not affect this prefix's access):
TYPE   GRANTEE               PERMISSION  GRANTED_BY  SOURCE  GRANTED_AT
email  shouldnotcount@x.com  read        prs_X       d/*     2026-05-13
A
    ;;
    inherited-only)
cat <<'A'
ACL for knowledge/y.md (restricted)
Direct entries (granted on this prefix):
TYPE   GRANTEE  PERMISSION  GRANTED_BY  GRANTED_AT
Inherited (granted on an ancestor prefix):
TYPE    GRANTEE         PERMISSION  GRANTED_BY  SOURCE       GRANTED_AT
email   corey@corp.com  read        prs_X       knowledge/*  2026-05-20
company-wide  Everyone in company  read  prs_X  knowledge/*  2026-06-01
A
    ;;
    root-shadow)
cat <<'A'
ACL for knowledge/readme.md (restricted)
No direct ACL row — access flows from the inherited/descendant grants below.

Inherited (granted on an ancestor prefix):
TYPE   GRANTEE         PERMISSION  GRANTED_BY  SOURCE       GRANTED_AT
email  jacob@corp.com  read        prs_X       *            2026-05-20
email  corey@corp.com  read        prs_X       knowledge/*  2026-07-10
A
    ;;
    open)
cat <<'A'
ACL for knowledge/z.md (open)
Direct entries (granted on this prefix):
TYPE   GRANTEE  PERMISSION  GRANTED_BY  GRANTED_AT
A
    ;;
  esac
  exit 0
fi
if [ "$1" = "members" ] && [ "$2" = "list" ]; then printf 'jacob@corp.com owner J\ncorey@corp.com owner C\n'; exit 0; fi
exit 1
HQ
chmod +x "$SBIN/hq"

RS="$(new_root slack)"; mkdir -p "$RS/workspace/.hq-pack-agent" "$RS/companies/acme/knowledge"
# sender jacob is NOT in members[] -> must still appear (F13 sender-union); GUEST uppercased + duplicated (F16)
cat > "$RS/workspace/.hq-pack-agent/slack-context.json" <<'J'
{"channel":{"name":"deals"},"sender":{"email":"jacob@corp.com"},
 "members":[{"email":"corey@corp.com"},{"email":"GUEST@EXT.com"},{"email":"guest@ext.com"}]}
J
sctx() { printf '' | env HQ_PACK_AGENT_FORCE_AGENT=1 "HQ_PACK_AGENT_HQ_ROOT=$RS" "CLAUDE_PROJECT_DIR=$RS" bash "$PKG/hooks/agent-slack-context.sh" 2>/dev/null; }
SCTX="$(sctx)"
assert_contains "slack-context: names the sender email" "$SCTX" "jacob@corp.com"
assert_contains "slack-context: lists a channel member" "$SCTX" "corey@corp.com"
assert_contains "slack-context: labels the channel" "$SCTX" "#deals"
NOCTX="$(printf '' | env HQ_PACK_AGENT_FORCE_AGENT=1 "HQ_PACK_AGENT_HQ_ROOT=$(new_root noslack)" bash "$PKG/hooks/agent-slack-context.sh" 2>/dev/null)"
assert_eq "slack-context: silent without any Slack context" "$NOCTX" ""
# F17: env fallback + precedence (explicit env when no file); and file beats env
RE="$(new_root slackenv)"; mkdir -p "$RE/workspace/.hq-pack-agent"
ENVOUT="$(printf '' | env HQ_PACK_AGENT_FORCE_AGENT=1 "HQ_PACK_AGENT_HQ_ROOT=$RE" HQ_SLACK_CHANNEL_NAME=envchan HQ_SLACK_SENDER_EMAIL=env-sender@corp.com "HQ_SLACK_MEMBER_EMAILS=a@corp.com, b@corp.com" bash "$PKG/hooks/agent-slack-context.sh" 2>/dev/null)"
assert_contains "slack-context(env): sender from env" "$ENVOUT" "env-sender@corp.com"
assert_contains "slack-context(env): members from env list" "$ENVOUT" "b@corp.com"
# F17 precedence: an explicit HQ_SLACK_CONTEXT_FILE beats conflicting env values
printf '%s' '{"channel":{"name":"filechan"},"sender":{"email":"fileuser@corp.com"},"members":[{"email":"fileuser@corp.com"}]}' > "$RE/ctx.json"
PREC="$(printf '' | env HQ_PACK_AGENT_FORCE_AGENT=1 "HQ_PACK_AGENT_HQ_ROOT=$RE" "HQ_SLACK_CONTEXT_FILE=$RE/ctx.json" HQ_SLACK_CHANNEL_NAME=envchan HQ_SLACK_SENDER_EMAIL=envuser@corp.com bash "$PKG/hooks/agent-slack-context.sh" 2>/dev/null)"
assert_contains "precedence: explicit file beats env" "$PREC" "#filechan"
assert_not_contains "precedence: env ignored when explicit file present" "$PREC" "envchan"

echo "== company-file-access: winner-only (most-specific) + safety fallbacks =="
fa() { printf '%s' "{\"tool_input\":{\"file_path\":\"$3\"}}" | env "PATH=$SBIN:$PATH" "$1" "ACL_MODE=$2" "HQ_PACK_AGENT_HQ_ROOT=$RS" "CLAUDE_PROJECT_DIR=$RS" bash "$PKG/hooks/agent-company-file-access.sh" 2>/dev/null; }
clearcache() { rm -rf "$RS/workspace/.hq-pack-agent/acl-cache"; }

# F2: Direct ACL shadows Inherited — only jacob (direct); corey (inherited email + company-wide) is NOT confirmed
clearcache; FO="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 direct-shadow "$RS/companies/acme/knowledge/x.md")"
assert_contains "winner-only: direct grantee jacob WITH access" "$FO" "jacob@corp.com"
assert_contains "winner-only: shadowed inherited corey is WITHOUT confirmed access" "$FO" "corey@corp.com"
# corey must appear under WITHOUT, not WITH: the do-not-share warning must fire
assert_contains "winner-only: do-not-share warning fires" "$FO" "DO NOT share"
assert_contains "winner-only: exact non-exhaustive command" "$FO" "hq files acl 'knowledge/x.md' --company acme"
assert_not_contains "winner-only: descendant grant excluded" "$FO" "shouldnotcount"

# No Direct ACL -> inherited layer wins: corey(email)+jacob(company-wide member) WITH, guest WITHOUT
clearcache; IO="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 inherited-only "$RS/companies/acme/knowledge/y.md")"
assert_contains "inherited-winner: corey (email) has access" "$IO" "corey@corp.com"
assert_contains "inherited-winner: jacob (company-wide member) has access" "$IO" "jacob@corp.com"
assert_contains "inherited-winner: guest (outsider) flagged do-not-share" "$IO" "DO NOT share"

# F1: open ACL -> company-wide read for all company members (jacob, corey); guest outsider not
clearcache; OO="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 open "$RS/companies/acme/knowledge/z.md")"
assert_contains "open-acl: company member jacob has access" "$OO" "jacob@corp.com"
assert_contains "open-acl: outsider guest flagged do-not-share" "$OO" "DO NOT share"

# real-format most-specific: knowledge/* wins, root-* grant is SHADOWED (leak guard)
clearcache; RSH="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 root-shadow "$RS/companies/acme/knowledge/readme.md")"
WITHSEC="$(printf '%s' "$RSH" | sed -n '/WITH access/,/WITHOUT/p')"
case "$WITHSEC" in *jacob*) bad "root-shadow: root-* grantee jacob wrongly WITH access";; *corey*) ok "root-shadow: only knowledge/* grantee corey is WITH; root-* jacob shadowed";; *) bad "root-shadow: unexpected WITH section";; esac
assert_contains "root-shadow: shadowed jacob triggers do-not-share" "$RSH" "DO NOT share"
# empty ACL output -> conservative, never all-clear
clearcache; EO="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 empty "$RS/companies/acme/knowledge/x.md")"
assert_contains "empty-acl: conservative could-not-resolve" "$EO" "Could not resolve"
assert_not_contains "empty-acl: never claims all-clear" "$EO" "All current channel members"

# scope/session guards
clearcache; assert_eq "file-access: non-company path is silent" "$(fa HQ_PACK_AGENT_FORCE_AGENT=1 direct-shadow "$RS/core/x.md")" ""
clearcache; assert_eq "file-access: human session is silent" "$(fa HQ_PACK_AGENT_FORCE_HUMAN=1 direct-shadow "$RS/companies/acme/knowledge/x.md")" ""
# F21 boundary: misleading names must NOT be treated as company paths
clearcache; assert_eq "file-access: 'companies' only in filename is not a company path" "$(fa HQ_PACK_AGENT_FORCE_AGENT=1 direct-shadow "$RS/core/companies-report.md")" ""

# F19: ACL fetch failure -> conservative fallback, exact command, NEVER an all-clear
clearcache; FF="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 fail "$RS/companies/acme/knowledge/x.md")"
assert_contains "acl-failure: says it could not resolve" "$FF" "Could not resolve"
assert_contains "acl-failure: still prints the manual command" "$FF" "hq files acl 'knowledge/x.md' --company acme"
assert_not_contains "acl-failure: never claims all members have access" "$FF" "All current channel members"
# F20 / F4-mechanism: a failed fetch is NOT cached — a later success recovers
SS="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 direct-shadow "$RS/companies/acme/knowledge/x.md")"
assert_contains "cache: failed fetch not cached, later success resolves access" "$SS" "jacob@corp.com"

# no-roster fallback: general who-can-access summary, no channel phrasing
rm -f "$RS/workspace/.hq-pack-agent/slack-context.json"; clearcache
NR="$(fa HQ_PACK_AGENT_FORCE_AGENT=1 direct-shadow "$RS/companies/acme/knowledge/x.md")"
assert_contains "file-access(no roster): general who-can-access summary" "$NR" "Who can access this company file"
assert_not_contains "file-access(no roster): no channel-member phrasing" "$NR" "Channel members WITHOUT"

echo "== install wiring is asserted structurally (F15) =="
RW="$(new_root wiring)"
HQ_PACK_AGENT_HQ_ROOT="$RW" bash "$PKG/install/install.sh" >/dev/null 2>&1
SL="$RW/.claude/settings.local.json"
ss_has() { jq -e --arg e "$1" --arg m "$2" --arg id "$3" '.hooks[$e][] | select(($m=="" ) or (.matcher==$m)) | .hooks[] | select((.command|contains("gate.sh\" "+$id+" ")) and (.command|endswith($id+".sh\"")))' "$SL" >/dev/null 2>&1; }
ss_has SessionStart "" agent-slack-context && ok "wiring: SessionStart runs agent-slack-context" || bad "wiring: SessionStart agent-slack-context missing"
ss_has PreToolUse Read agent-company-file-access && ok "wiring: PreToolUse/Read runs agent-company-file-access" || bad "wiring: PreToolUse/Read agent-company-file-access missing"
if grep -q 'agent-file-access\.sh' "$SL"; then bad "wiring: retired agent-file-access.sh must be absent"; else ok "wiring: retired PostToolUse agent-file-access absent"; fi
echo "== agent-slack-guard: block long sends / advise short =="
guard() {  # $1=payload json; rest=env KEY=VAL. Sets G_OUT G_ERR G_RC.
  local p="$1"; shift
  G_OUT="$(printf '%s' "$p" | env "$@" bash "$PKG/hooks/agent-slack-guard.sh" 2>"$TMP/guard.err")"; G_RC=$?
  G_ERR="$(cat "$TMP/guard.err" 2>/dev/null)"
}
LONGCMD="slack-call chat.postMessage $(printf 'x%.0s' $(seq 1 2500))"
# Long outbound send in an agent session -> HARD BLOCK (exit 2 + /deploy redirect).
guard "{\"tool_input\":{\"command\":\"$LONGCMD\"}}" HQ_PACK_AGENT_FORCE_AGENT=1
assert_eq "guard: long send exits 2 (blocked)" "$G_RC" "2"
assert_contains "guard: block says BLOCKED" "$G_ERR" "BLOCKED"
assert_contains "guard: block redirects to /deploy" "$G_ERR" "/deploy"
assert_eq "guard: block writes nothing to stdout" "$G_OUT" ""
# Short outbound send -> advisory only (exit 0, stdout reminder, no block).
guard '{"tool_input":{"command":"slack-call chat.postMessage {\"text\":\"Done, it is live: https://x.io/a\"}"}}' HQ_PACK_AGENT_FORCE_AGENT=1
assert_eq "guard: short send exits 0" "$G_RC" "0"
assert_contains "guard: short send advises" "$G_OUT" "Outbound message detected"
assert_not_contains "guard: short send not blocked" "$G_ERR" "BLOCKED"
# A raised custom limit lets a long send through (advisory, not blocked).
guard "{\"tool_input\":{\"command\":\"$LONGCMD\"}}" HQ_PACK_AGENT_FORCE_AGENT=1 HQ_SLACK_MAX_REPLY_CHARS=9000
assert_eq "guard: raised limit allows the long send" "$G_RC" "0"
assert_not_contains "guard: raised limit not blocked" "$G_ERR" "BLOCKED"
# Non-message command -> inert (silent, exit 0).
guard '{"tool_input":{"command":"ls -la /tmp"}}' HQ_PACK_AGENT_FORCE_AGENT=1
assert_eq "guard: non-message exits 0" "$G_RC" "0"
assert_eq "guard: non-message is silent" "$G_OUT" ""
# Human session -> never blocks, even a long send (fail-open).
guard "{\"tool_input\":{\"command\":\"$LONGCMD\"}}" HQ_PACK_AGENT_FORCE_HUMAN=1
assert_eq "guard: human session never blocks" "$G_RC" "0"

echo "== gate propagates a deliberate exit-2 block (but nothing else) =="
# Production path: hooks run THROUGH agent-pack-gate.sh. A block must survive it.
printf '%s' "{\"tool_input\":{\"command\":\"$LONGCMD\"}}" | env HQ_PACK_AGENT_FORCE_AGENT=1 bash "$PKG/hooks/agent-pack-gate.sh" agent-slack-guard "$PKG/hooks/agent-slack-guard.sh" >"$TMP/gate.out" 2>"$TMP/gate.err"
assert_eq "gate: long send blocked THROUGH the gate (exit 2)" "$?" "2"
assert_contains "gate: block reason reaches stderr through the gate" "$(cat "$TMP/gate.err")" "/deploy"
# A hook that errors non-deliberately (exit 1) still fails OPEN through the gate.
ERRHOOK="$TMP/errhook.sh"; printf '#!/bin/bash\ncat >/dev/null 2>&1\nexit 1\n' > "$ERRHOOK"; chmod +x "$ERRHOOK"
echo '{}' | env HQ_PACK_AGENT_FORCE_AGENT=1 bash "$PKG/hooks/agent-pack-gate.sh" errhook "$ERRHOOK" >/dev/null 2>&1
assert_eq "gate: a non-2 hook error fails OPEN (exit 0)" "$?" "0"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
