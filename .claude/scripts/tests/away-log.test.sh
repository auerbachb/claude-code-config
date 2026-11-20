#!/usr/bin/env bash
# catalog: tests — Proves away-log.sh: append with secret refusal, newline folding, session/repo/--all scoped reads, and bad lines skipped rather than fatal
# Tests for away-log.sh (issue #2594): append, secret refusal, scoped reads, bad lines skipped.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
AL="$REPO_ROOT/.claude/scripts/away-log.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export AWAY_LOG_DIR="$tmp/log"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
A() { rc=0; out=$(cd "$REPO_ROOT" && "$AL" "$@" 2>"$tmp/err") || rc=$?; }

A append --kind merged --text "merged PR #1" --session s1 --now 100
check "append exits 0" "$rc" 0
check "append prints the entry" "$(printf '%s' "$out" | jq -r '"\(.kind)|\(.text)|\(.session)|\(.at)"')" "merged|merged PR #1|s1|100"
A append --kind owner-task --text $'sign in\nto Vercel' --session s1 --now 300
check "newlines folded to one line" "$(printf '%s' "$out" | jq -r .text)" "sign in to Vercel"
A append --kind blocker --text "CI red on main" --session s2 --now 200
A append --kind nope --text x --session s1; check "unknown kind: usage error" "$rc" 2
A append --kind note --session s1; check "missing text: usage error" "$rc" 2
A append --kind note --text "   " --session s1; check "blank text: usage error" "$rc" 2
A append --kind note --text "token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" --session s1
check "secret-looking text refused" "$rc" 5
A append --kind note --text "$(printf 'x%.0s' $(seq 1 2001))" --session s1
check "text over 2000 bytes: usage error" "$rc" 2
A read --session s1; check "secret was not stored" "$(printf '%s' "$out" | jq length)" 2

A read --session s1; check "session scope, oldest first" "$(printf '%s' "$out" | jq -r '[.[].at] | join(",")')" "100,300"
A read --session s1 --since 200; check "--since filters" "$(printf '%s' "$out" | jq -r '[.[].at] | join(",")')" "300"
A read; check "no session: every session of this repo, sorted" "$(printf '%s' "$out" | jq -r '[.[].at] | join(",")')" "100,200,300"
A read --session nobody; check "unknown session: empty array" "$out" "[]"
F=$(cd "$REPO_ROOT" && "$AL" path --session s1)
printf 'not json\n' >>"$F"
A read --session s1; check "a bad line is skipped, the rest read" "$rc:$(printf '%s' "$out" | jq length)" "0:2"
mkdir -p "$tmp/other"; (cd "$tmp/other" && git init -q && "$AL" append --kind note --text "elsewhere" --session s9 --now 50 >/dev/null)
A read --all; check "--all: every repo" "$(printf '%s' "$out" | jq length)" 4
AWAY_LOG_DIR="$tmp/none" A read --all; check "no log directory: empty array" "$rc:$out" "0:[]"
D=$(dirname "$F"); chmod 000 "$D"
A read --session s1; check "unreadable repo directory: exit 1, not an empty list" "$rc" 1
chmod 755 "$D"
A read --since soon; check "bad --since: usage error" "$rc" 2
A bogus; check "unknown command: usage error" "$rc" 2
A --help; check "--help exits 0" "$rc" 0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
