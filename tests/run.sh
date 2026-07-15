#!/usr/bin/env bash
# run.sh — hq-pack-agent test suite (no shortcuts; real regression coverage).
#
# Covers every acceptance requirement from the build spec:
#   * agent-gate: no-op for human sessions, active for agent sessions
#   * is-agent detection precedence (force flags, markers, default-inert)
#   * updater: local<remote triggers; equal/greater does not; TTL throttle;
#     cache-delete forces re-check
#   * autonomous hq maintenance: agent-gated, throttled hq-cli update and
#     detached hq rescue when hq-core is behind
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
record_call() {
  [ -n "${FAKE_CALL_RECORD:-}" ] && printf 'gh %s\n' "$*" >> "$FAKE_CALL_RECORD"
  [ -n "${FAKE_NETWORK_SLEEP:-}" ] && sleep "$FAKE_NETWORK_SLEEP"
}
case "$*" in
  "auth status") record_call "$@"; [ "${FAKE_GH_AUTH:-0}" = "1" ] && exit 0 || exit 1 ;;
  "auth token")  [ "${FAKE_GH_AUTH:-0}" = "1" ] && { echo "ghp_FAKEfaketoken000000000000000000000000"; exit 0; } || exit 1 ;;
  *"release view"*) record_call "$@"; [ -n "${FAKE_GH_TAG:-}" ] && { echo "$FAKE_GH_TAG"; exit 0; } || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin/hq" <<'EOF'
#!/bin/bash
case "$1" in
  secrets)
    [ "$2" = "get" ] || exit 1
    [ -n "${FAKE_HQ_SECRET:-}" ] && { printf '%s\n' "$FAKE_HQ_SECRET"; exit 0; }
    exit 0
    ;;
  --version)
    [ -n "${FAKE_CALL_RECORD:-}" ] && printf 'hq --version\n' >> "$FAKE_CALL_RECORD"
    [ -n "${FAKE_NETWORK_SLEEP:-}" ] && sleep "$FAKE_NETWORK_SLEEP"
    [ -n "${FAKE_HQ_CLI_VERSION:-}" ] && { printf 'hq %s\n' "$FAKE_HQ_CLI_VERSION"; exit 0; }
    exit 1
    ;;
  rescue)
    [ -n "${FAKE_RECORD_DIR:-}" ] && { mkdir -p "$FAKE_RECORD_DIR"; printf '%s\n' "$*" >> "$FAKE_RECORD_DIR/rescue.log"; }
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin/npm" <<'EOF'
#!/bin/bash
case "$1" in
  view)
    [ -n "${FAKE_CALL_RECORD:-}" ] && printf 'npm %s\n' "$*" >> "$FAKE_CALL_RECORD"
    [ -n "${FAKE_NETWORK_SLEEP:-}" ] && sleep "$FAKE_NETWORK_SLEEP"
    [ -n "${FAKE_NPM_VERSION:-}" ] && { printf '%s\n' "$FAKE_NPM_VERSION"; exit 0; }
    exit 1
    ;;
  install)
    [ -n "${FAKE_RECORD_DIR:-}" ] && { mkdir -p "$FAKE_RECORD_DIR"; printf '%s\n' "$*" >> "$FAKE_RECORD_DIR/npm-install.log"; }
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  # Hermetic curl: the updater's unauthenticated fallback hits GitHub's
  # releases/latest — stub it (mirrors the gh stub via FAKE_GH_TAG) so tests
  # never touch the network (a real fetch would find the actual latest release).
  cat > "$bin/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *"releases/latest"*)
    [ -n "${FAKE_CALL_RECORD:-}" ] && printf 'curl %s\n' "$*" >> "$FAKE_CALL_RECORD"
    [ -n "${FAKE_NETWORK_SLEEP:-}" ] && sleep "$FAKE_NETWORK_SLEEP"
    [ -n "${FAKE_GH_TAG:-}" ] && { printf '{"tag_name":"%s"}\n' "$FAKE_GH_TAG"; exit 0; } || exit 1
    ;;
  *) exit 1 ;;
esac
EOF
  # These shims let the self-update tests either execute a detached body inline
  # (and mark completion) or record the fork without running its command.
  cat > "$bin/setsid" <<'EOF'
#!/bin/bash
[ -n "${FAKE_FORK_RECORD:-}" ] && printf 'setsid %s\n' "$*" >> "$FAKE_FORK_RECORD"
[ "${FAKE_FORK_MODE:-passthrough}" = "record-only" ] && exit 0
"$@"
status=$?
case "$*" in
  *"--hq-selfupdate-background"*) [ -n "${FAKE_OUTER_FORK_DONE:-}" ] && printf 'done\n' > "$FAKE_OUTER_FORK_DONE" ;;
esac
exit "$status"
EOF
  cat > "$bin/nohup" <<'EOF'
#!/bin/bash
[ -n "${FAKE_FORK_RECORD:-}" ] && printf 'nohup %s\n' "$*" >> "$FAKE_FORK_RECORD"
[ "${FAKE_FORK_MODE:-passthrough}" = "record-only" ] && exit 0
"$@"
status=$?
case "$*" in
  *"--hq-selfupdate-background"*) [ -n "${FAKE_OUTER_FORK_DONE:-}" ] && printf 'done\n' > "$FAKE_OUTER_FORK_DONE" ;;
esac
exit "$status"
EOF
  chmod +x "$bin/gh" "$bin/hq" "$bin/npm" "$bin/curl" "$bin/setsid" "$bin/nohup"
}

# Detached children should record virtually immediately, but tolerate scheduler
# variance without making the suite depend on a particular setsid implementation.
wait_for_record() {
  local f="$1" i=0
  while [ "$i" -lt 20 ]; do
    [ -s "$f" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
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

echo "== agent-startwork: fresh agent startups only =="
startwork() { printf '%s' "$1" | env "${@:2}" bash "$PKG/hooks/agent-startwork.sh" 2>/dev/null; }
START_HUMAN="$(startwork '{"source":"startup"}' HQ_PACK_AGENT_FORCE_HUMAN=1)"
assert_eq "startwork: non-agent session is silent" "$START_HUMAN" ""
START_RESUME="$(startwork '{"source":"resume"}' HQ_PACK_AGENT_FORCE_AGENT=1)"
assert_eq "startwork: non-startup source is silent" "$START_RESUME" ""
START_AGENT="$(startwork '{"source":"startup"}' HQ_PACK_AGENT_FORCE_AGENT=1 HQ_COMPANY=acme)"
assert_contains "startwork: agent startup emits directive" "$START_AGENT" "<hq-pack-agent-startwork>"
assert_contains "startwork: agent startup runs startwork first" "$START_AGENT" "/startwork acme as your FIRST action"

echo "== agent-learn-handoff: invoke the core handoff skill =="
HANDOFF="$(printf '{}' | env HQ_PACK_AGENT_FORCE_AGENT=1 bash "$PKG/hooks/agent-learn-handoff.sh" 2>/dev/null)"
assert_contains "handoff: keeps checkpoint guidance" "$HANDOFF" "Save a checkpoint"
assert_contains "handoff: directs the core handoff skill" "$HANDOFF" "Run /handoff now"
assert_contains "handoff: keeps learn guidance" "$HANDOFF" "/learn"

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

echo "== agent-hq-selfupdate: detached autonomous maintenance =="
R5="$(new_root hq-selfupdate)"; BIN5="$TMP/bin-hq-selfupdate"; make_stubs "$BIN5"
SELF_STATE="$R5/workspace/.hq-pack-agent"
SELF_RECORDS="$R5/records"
SELF_PROBES="$R5/probes"; mkdir -p "$SELF_PROBES"
SELF_FORKS="$SELF_PROBES/forks.log"
SELF_CALLS="$SELF_PROBES/network-calls.log"
SELF_DONE="$SELF_PROBES/background-done"
run_selfupdate() { # env-configured; stdin closes immediately like a real SessionStart hook.
  ( export PATH="$BIN5:$PATH" HQ_PACK_AGENT_HQ_ROOT="$R5" HQ_PACK_AGENT_FORCE_AGENT=1
    "$@" bash "$PKG/hooks/agent-hq-selfupdate.sh" </dev/null 2>/dev/null )
}
# (a) Human sessions never initialize state, fork, make a network call, or print.
rm -rf "$SELF_STATE" "$SELF_RECORDS"; rm -f "$SELF_FORKS" "$SELF_CALLS" "$SELF_DONE"
out="$(env PATH="$BIN5:$PATH" HQ_PACK_AGENT_HQ_ROOT="$R5" HQ_PACK_AGENT_FORCE_HUMAN=1 FAKE_HQ_CLI_VERSION=1.0.0 FAKE_NPM_VERSION=2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_FORK_RECORD="$SELF_FORKS" FAKE_CALL_RECORD="$SELF_CALLS" FAKE_FORK_MODE=record-only bash "$PKG/hooks/agent-hq-selfupdate.sh" </dev/null 2>/dev/null)"
assert_eq "hq-selfupdate: non-agent session is silent" "$out" ""
assert_nofile "$SELF_STATE" "hq-selfupdate: non-agent session schedules no work"
assert_nofile "$SELF_FORKS" "hq-selfupdate: non-agent session forks nothing"
assert_nofile "$SELF_CALLS" "hq-selfupdate: non-agent session makes no network call"
# (b) A fresh 24-hour cache stops all update checks before they begin or fork.
mkdir -p "$SELF_STATE"; printf '{"latest":"9.9.9"}\n' > "$SELF_STATE/hq-selfupdate-last-check.json"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_FORKS" "$SELF_CALLS" "$SELF_DONE"
out="$(FAKE_HQ_CLI_VERSION=1.0.0 FAKE_NPM_VERSION=2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_FORK_RECORD="$SELF_FORKS" FAKE_CALL_RECORD="$SELF_CALLS" FAKE_FORK_MODE=record-only run_selfupdate env)"
assert_eq "hq-selfupdate: fresh cache throttles silently" "$out" ""
assert_nofile "$SELF_RECORDS/npm-install.log" "hq-selfupdate: fresh cache schedules no cli install"
assert_nofile "$SELF_RECORDS/rescue.log" "hq-selfupdate: fresh cache schedules no rescue"
assert_nofile "$SELF_FORKS" "hq-selfupdate: fresh cache forks nothing"
assert_nofile "$SELF_CALLS" "hq-selfupdate: fresh cache makes no network call"
# (c) An old CLI runs in the detached body and schedules an npm install.
rm -f "$SELF_STATE/hq-selfupdate-last-check.json" "$SELF_STATE/hq-cli-auto-update.stamp" "$SELF_STATE/hq-core-rescue.stamp"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_FORKS" "$SELF_CALLS" "$SELF_DONE"
out="$(FAKE_HQ_CLI_VERSION=1.0.0 FAKE_NPM_VERSION=2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_FORK_RECORD="$SELF_FORKS" FAKE_CALL_RECORD="$SELF_CALLS" FAKE_OUTER_FORK_DONE="$SELF_DONE" run_selfupdate env)"
assert_eq "hq-selfupdate: old cli remains silent" "$out" ""
wait_for_record "$SELF_DONE" && ok "hq-selfupdate: old cli runs the detached body" || bad "hq-selfupdate: old cli runs the detached body"
wait_for_record "$SELF_RECORDS/npm-install.log" && ok "hq-selfupdate: old cli schedules detached npm install" || bad "hq-selfupdate: old cli schedules detached npm install"
assert_contains "hq-selfupdate: npm install targets latest cli" "$(cat "$SELF_RECORDS/npm-install.log" 2>/dev/null)" "install -g @indigoai-us/hq-cli@latest"
assert_contains "hq-selfupdate: cli scheduling outcome is logged" "$(cat "$SELF_STATE/debug.log" 2>/dev/null)" "hq-cli update scheduled 1.0.0->2.0.0"
# (d) An equal/current CLI never schedules another install.
rm -f "$SELF_STATE/hq-selfupdate-last-check.json" "$SELF_STATE/hq-cli-auto-update.stamp"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_DONE"
out="$(FAKE_HQ_CLI_VERSION=2.0.0 FAKE_NPM_VERSION=2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_OUTER_FORK_DONE="$SELF_DONE" run_selfupdate env)"
assert_eq "hq-selfupdate: current cli remains silent" "$out" ""
wait_for_record "$SELF_DONE" && ok "hq-selfupdate: current cli runs the detached body" || bad "hq-selfupdate: current cli runs the detached body"
assert_nofile "$SELF_RECORDS/npm-install.log" "hq-selfupdate: current cli schedules no install"
# (e) A newer public core release uses the curl fallback and schedules hq rescue.
mkdir -p "$R5/core"; printf 'hqVersion: 1.0.0\n' > "$R5/core/core.yaml"
rm -f "$SELF_STATE/hq-selfupdate-last-check.json" "$SELF_STATE/hq-core-rescue.stamp"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_DONE"
out="$(FAKE_GH_AUTH=0 FAKE_GH_TAG=v2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_OUTER_FORK_DONE="$SELF_DONE" run_selfupdate env)"
assert_eq "hq-selfupdate: newer core remains silent" "$out" ""
wait_for_record "$SELF_RECORDS/rescue.log" && ok "hq-selfupdate: newer core schedules detached rescue" || bad "hq-selfupdate: newer core schedules detached rescue"
assert_contains "hq-selfupdate: rescue receives HQ root" "$(cat "$SELF_RECORDS/rescue.log" 2>/dev/null)" "rescue --hq-root $R5 --yes"
assert_contains "hq-selfupdate: rescue scheduling outcome is logged" "$(cat "$SELF_STATE/debug.log" 2>/dev/null)" "hq rescue scheduled 1.0.0->2.0.0"
# (f) Equal hq-core versions never schedule rescue.
printf 'hqVersion: 2.0.0\n' > "$R5/core/core.yaml"
rm -f "$SELF_STATE/hq-selfupdate-last-check.json" "$SELF_STATE/hq-core-rescue.stamp"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_DONE"
out="$(FAKE_GH_AUTH=0 FAKE_GH_TAG=v2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_OUTER_FORK_DONE="$SELF_DONE" run_selfupdate env)"
assert_eq "hq-selfupdate: current core remains silent" "$out" ""
wait_for_record "$SELF_DONE" && ok "hq-selfupdate: current core runs the detached body" || bad "hq-selfupdate: current core runs the detached body"
assert_nofile "$SELF_RECORDS/rescue.log" "hq-selfupdate: current core schedules no rescue"
# (g) A record-only outer fork proves that SessionStart never performs lookups.
rm -f "$SELF_STATE/hq-selfupdate-last-check.json" "$SELF_STATE/hq-cli-auto-update.stamp" "$SELF_STATE/hq-core-rescue.stamp"
rm -rf "$SELF_RECORDS"; rm -f "$SELF_FORKS" "$SELF_CALLS" "$SELF_DONE"
SECONDS=0
out="$(FAKE_HQ_CLI_VERSION=1.0.0 FAKE_NPM_VERSION=2.0.0 FAKE_GH_AUTH=0 FAKE_GH_TAG=v2.0.0 FAKE_RECORD_DIR="$SELF_RECORDS" FAKE_FORK_RECORD="$SELF_FORKS" FAKE_CALL_RECORD="$SELF_CALLS" FAKE_FORK_MODE=record-only FAKE_NETWORK_SLEEP=2 run_selfupdate env)"
elapsed="$SECONDS"
wait_for_record "$SELF_FORKS" && ok "hq-selfupdate: non-blocking path forks its background body" || bad "hq-selfupdate: non-blocking path forks its background body"
assert_eq "hq-selfupdate: non-blocking path remains silent" "$out" ""
assert_nofile "$SELF_CALLS" "hq-selfupdate: synchronous path makes zero network calls"
[ "$elapsed" -lt 2 ] && ok "hq-selfupdate: record-only fork adds no blocking wait" || bad "hq-selfupdate: record-only fork adds no blocking wait" "elapsed ${elapsed}s"

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
assert_contains "install wired agent-hq-selfupdate into settings" "$FIRST" "agent-hq-selfupdate.sh"
assert_contains "install wired agent-startwork into settings" "$FIRST" "agent-startwork.sh"
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
ss_has SessionStart "" agent-hq-selfupdate && ok "wiring: SessionStart runs agent-hq-selfupdate" || bad "wiring: SessionStart agent-hq-selfupdate missing"
ss_has SessionStart "" agent-startwork && ok "wiring: SessionStart runs agent-startwork" || bad "wiring: SessionStart agent-startwork missing"
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
