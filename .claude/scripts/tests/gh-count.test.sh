#!/usr/bin/env bash
# gh-count.test.sh — Offline tests for the per-run GitHub REST call count (issue #2441).
# catalog: tests — Tests the opt-in REST call counter in lib/gh-count.sh and its hook in merge-gate.sh, polling-state-gate.sh and escalate-review.sh
#
# No test calls GitHub: `gh` is a stub that prints the request log the real gh prints
# under GH_DEBUG=api. Run from repo root: bash .claude/scripts/tests/gh-count.test.sh
# covers: .claude/scripts/lib/gh-count.sh .claude/scripts/merge-gate.sh .claude/scripts/polling-state-gate.sh .claude/scripts/escalate-review.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPTS="$REPO_ROOT/.claude/scripts"
LIB="$SCRIPTS/lib/gh-count.sh"
[[ -f "$LIB" ]] || { echo "FAIL: missing $LIB" >&2; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
# Start from a clean baseline: a caller's own counter settings must not leak into any case.
unset GH_REST_COUNT GH_REST_WARN_AT GH_REST_COUNT_ACTIVE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1" >&2; }
eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

# Stub gh. Under GH_DEBUG=api it prints one request-log block per request, the way gh does.
# `api <path>` makes FAKE_PAGES requests (a paginated call); `api graphql`, `pr view` and
# `repo view` make one GraphQL request; `api rate_limit` makes one free request. FAKE_FAIL=1
# makes every call print an error and exit 1.
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home/.claude"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
req() { # url remaining
  [[ "${GH_DEBUG:-}" == api ]] || return 0
  {
    echo "* Request at 2026-11-17 15:00:00.1 -0500 EST m=+0.02"
    echo "* Request to $1"
    echo "> GET /x HTTP/1.1"
    echo "> Authorization: token ████"
    echo
    echo "< HTTP/2.0 200 OK"
    echo "< X-Ratelimit-Remaining: $2"
    echo "< X-Ratelimit-Resource: core"
    echo
    echo '{"message":"debug body that must never reach the caller"}'
    echo
    echo "* Request took 10ms"
  } >&2
}
if [[ "${1:-}" == "__shape" ]]; then
  # Echoes what it received so a test can prove the shim passes arguments and stdin through unchanged.
  shift
  i=0
  for a in "$@"; do i=$((i + 1)); printf 'arg%s=[%s]\n' "$i" "$a"; done
  case " $* " in *" --input "*) printf 'stdin=[%s]\n' "$(cat)" ;; esac
  echo "shape-stderr-text" >&2
  exit "${FAKE_RC:-0}"
fi
# Under GH_DEBUG=api the real gh also logs the git commands it runs to find the repository
# ("[git remote -v]"), outside any request block. Real stdout is JSON; that log is not.
if [[ "${GH_DEBUG:-}" == api ]]; then
  case "$1 ${2:-}" in
    "pr view" | "repo view") { echo "[git remote -v]"; echo '[git config --get-regexp ^remote\..*\.gh-resolved$]'; } >&2 ;;
  esac
fi
case "$1 ${2:-}" in
  "api graphql" | "pr view" | "repo view") req https://api.github.com/graphql 4000 ;;
  "api rate_limit") req https://api.github.com/rate_limit 4000 ;;
  api*)
    i=0
    while [[ $i -lt "${FAKE_PAGES:-1}" ]]; do
      req "https://api.github.com/repos/o/r/pulls/1/reviews?page=$i" $((4900 - i))
      i=$((i + 1))
    done
    ;;
esac
echo "stub-stderr-line" >&2
if [[ -n "${FAKE_FAIL:-}" ]]; then echo "gh: boom (HTTP 500)" >&2; exit 1; fi
echo "stub-stdout $*"
exit "${FAKE_RC:-0}"
STUB
chmod +x "$BIN/gh"

# A probe script wired exactly like the three real ones: same hook, own lib/ directory.
PROBE_DIR="$TMP/probe"
mkdir -p "$PROBE_DIR/lib"
cp "$LIB" "$PROBE_DIR/lib/gh-count.sh"
cat >"$PROBE_DIR/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
if [[ -z "${GH_REST_COUNT_ACTIVE:-}" && ( -n "${GH_REST_COUNT:-}" || -n "${GH_REST_WARN_AT:-}" ) ]]; then
  . "$(dirname "${BASH_SOURCE[0]}")/lib/gh-count.sh" 2>/dev/null && gh_count_reexec "${BASH_SOURCE[0]}" "$@" || true
fi
gh api repos/o/r/pulls/1/reviews --paginate
gh api repos/o/r/pulls/1/comments
gh api graphql
gh pr view 1
gh api rate_limit
bash "$(dirname "${BASH_SOURCE[0]}")/child.sh"
exit "${PROBE_RC:-0}"
PROBE
cat >"$PROBE_DIR/child.sh" <<'CHILD'
#!/usr/bin/env bash
# A nested script: adds to the parent's tally, prints no report of its own.
gh api repos/o/r/issues/1/comments
CHILD
chmod +x "$PROBE_DIR/probe.sh"

run() { # env assignments are passed by the caller via env; sets OUT ERR RC
  OUT="$TMP/out"; ERR="$TMP/err"
  PATH="$BIN:$PATH" FAKE_PAGES="${FAKE_PAGES:-1}" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

echo "# off by default"
FAKE_PAGES=3 run env bash "$PROBE_DIR/probe.sh"
BASE_OUT="$(cat "$OUT")"; BASE_ERR="$(cat "$ERR")"; BASE_RC=$RC
case "$BASE_ERR" in *gh-count*|*WARNING*) bad "off: no count or warning line" ;; *) ok "off: no count or warning line" ;; esac
case "$BASE_ERR" in *"debug body"*) bad "off: gh is not run in debug mode" ;; *) ok "off: gh is not run in debug mode" ;; esac

echo "# on: the count"
FAKE_PAGES=3 run env GH_REST_COUNT=1 bash "$PROBE_DIR/probe.sh"
eq "on: stdout byte-identical to off" "$BASE_OUT" "$(cat "$OUT")"
eq "on: exit code identical to off" "$BASE_RC" "$RC"
# FAKE_PAGES=3 applies to every REST path: reviews x3, comments x3, nested child x3 = 9 REST;
# `api graphql` and `pr view` = 2 GraphQL; `api rate_limit` is free.
LINE="$(grep 'gh-count' "$ERR")"
eq "on: exactly one count line" "1" "$(grep -c 'gh-count' "$ERR")"
case "$LINE" in *"rest=9 graphql=2"*) ok "on: rest counts every page and nested scripts; graphql apart; rate_limit free" ;; *) bad "on: rest=9 graphql=2 (got: $LINE)" ;; esac
case "$LINE" in *"first=4900 last=4898"*) ok "on: GitHub's X-RateLimit-Remaining header is reported" ;; *) bad "on: remaining first=4900 last=4898 (got: $LINE)" ;; esac
eq "on: stderr minus the count line equals the off stderr" "$BASE_ERR" "$(grep -v 'gh-count' "$ERR")"

echo "# only an explicit setting turns it on"
FAKE_PAGES=3 run env GH_REST_COUNT=0 bash "$PROBE_DIR/probe.sh"
eq "GH_REST_COUNT=0 stays off" "$BASE_ERR" "$(cat "$ERR")"
FAKE_PAGES=3 run env GH_REST_WARN_AT=lots bash "$PROBE_DIR/probe.sh"
eq "a non-numeric GH_REST_WARN_AT stays off" "$BASE_ERR" "$(cat "$ERR")"

echo "# the warning"
FAKE_PAGES=3 run env GH_REST_WARN_AT=5 bash "$PROBE_DIR/probe.sh"
eq "warn: one warning line over the figure" "1" "$(grep -c 'WARNING' "$ERR")"
eq "warn: no count line without GH_REST_COUNT" "0" "$(grep -c 'gh-count' "$ERR")"
eq "warn: stdout and exit code unchanged" "$BASE_OUT|$BASE_RC" "$(cat "$OUT")|$RC"
FAKE_PAGES=3 run env GH_REST_WARN_AT=9 bash "$PROBE_DIR/probe.sh"
eq "warn: a run exactly at the figure prints nothing" "$BASE_ERR" "$(cat "$ERR")"
FAKE_PAGES=3 run env GH_REST_WARN_AT=100 bash "$PROBE_DIR/probe.sh"
eq "warn: a run under the figure prints nothing" "$BASE_ERR" "$(cat "$ERR")"

echo "# a count failure never changes the verdict"
FAKE_PAGES=3 PROBE_RC=7 run env bash "$PROBE_DIR/probe.sh"
BASE7_OUT="$(cat "$OUT")"; BASE7_ERR="$(cat "$ERR")"
FAKE_PAGES=3 PROBE_RC=7 run env GH_REST_COUNT=1 bash "$PROBE_DIR/probe.sh"
eq "exit code from the script passes through when counting" "7" "$RC"
eq "stdout identical when the script exits non-zero" "$BASE7_OUT" "$(cat "$OUT")"
FAKE_PAGES=3 PROBE_RC=7 run env GH_REST_COUNT=1 TMPDIR="$TMP/does-not-exist" bash "$PROBE_DIR/probe.sh"
eq "unavailable count: exit code unchanged" "7" "$RC"
eq "unavailable count: stdout unchanged" "$BASE7_OUT" "$(cat "$OUT")"
case "$(cat "$ERR")" in *"call count unavailable"*) ok "unavailable count: the script says so" ;; *) bad "unavailable count: the script says so (got: $(cat "$ERR"))" ;; esac
eq "unavailable count: otherwise stderr unchanged" "$BASE7_ERR" "$(grep -v 'call count unavailable' "$ERR")"
if [[ -x /usr/bin/gh || -x /bin/gh ]]; then
  echo "  skip - no gh on PATH (a system gh exists in /usr/bin or /bin)"
else
  FAKE_PAGES=3 PROBE_RC=7 run env GH_REST_COUNT=1 PATH="/usr/bin:/bin" bash "$PROBE_DIR/probe.sh"
  eq "no gh on PATH: exit code unchanged" "$(PROBE_RC=7 PATH=/usr/bin:/bin bash "$PROBE_DIR/probe.sh" >/dev/null 2>&1; echo $?)" "$RC"
fi

echo "# a call the shim could not capture marks the count unavailable"
# A mktemp that fails only for the shim's per-call capture file.
cat >"$BIN/mktemp" <<'MK'
#!/usr/bin/env bash
case "$*" in *gh-count-err*) exit 1 ;; esac
exec /usr/bin/mktemp "$@"
MK
chmod +x "$BIN/mktemp"
FAKE_PAGES=3 PROBE_RC=7 run env GH_REST_COUNT=1 bash "$PROBE_DIR/probe.sh"
case "$(cat "$ERR")" in *"call count unavailable"*) ok "uncapturable call: the script says the count is unavailable" ;; *) bad "uncapturable call: unavailable line (got: $(cat "$ERR"))" ;; esac
case "$(cat "$ERR")" in *"gh-count rest="*) bad "uncapturable call: no partial count printed as exact" ;; *) ok "uncapturable call: no partial count printed as exact" ;; esac
eq "uncapturable call: exit code unchanged" "7" "$RC"
rm -f "$BIN/mktemp"

echo "# gh failures are passed through"
FAKE_FAIL=1 FAKE_PAGES=2 run env bash "$PROBE_DIR/probe.sh"
F_OUT="$(cat "$OUT")"; F_ERR="$(cat "$ERR")"
FAKE_FAIL=1 FAKE_PAGES=2 run env GH_REST_COUNT=1 bash "$PROBE_DIR/probe.sh"
eq "failing gh: stdout identical" "$F_OUT" "$(cat "$OUT")"
eq "failing gh: gh's own error text is kept" "$F_ERR" "$(grep -v 'gh-count' "$ERR")"

echo "# every call shape passes through the shim unchanged"
# pr-state.sh and others capture `gh ... 2>&1` and parse it as JSON: gh's debug logging must
# never reach the caller, not even the "[git ...]" lines gh prints outside its request blocks.
cat >"$TMP/shape.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
if [[ -z "${GH_REST_COUNT_ACTIVE:-}" && -n "${GH_REST_COUNT:-}" ]]; then
  . "$LIBDIR/gh-count.sh" && gh_count_reexec "${BASH_SOURCE[0]}" "$@" || true
fi
echo "A:"; gh pr view 1 --json number 2>&1
echo "B:"; gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1
echo "C:"; gh api graphql -f query='query($o: String!) { x }' -F n=1 2>&1
echo "D:"; printf '{"k":"v w"}\n' | gh api repos/o/r/x --input - 2>&1
echo "E:"; gh api --paginate 'repos/o/r/x?per_page=100' --jq '.[] | .a b' 2>&1
echo "F:"; gh __shape 'two words' '' "quote'd" '$HOME' -q '.a|.b' 2>&1
echo "G:"; printf 'in-data' | gh __shape --input - 2>&1
FAKE_RC=3 gh __shape x >/dev/null 2>&1; echo "H:rc=$?"
echo "I:$(FAKE_RC=3 gh __shape err 2>&1 >/dev/null)"
SH
cp "$LIB" "$TMP/gh-count.sh"
SHAPE_OFF="$(PATH="$BIN:$PATH" LIBDIR="$TMP" bash "$TMP/shape.sh" 2>&1)"
SHAPE_ON="$(PATH="$BIN:$PATH" LIBDIR="$TMP" GH_REST_COUNT=1 bash "$TMP/shape.sh" 2>&1 | grep -v 'gh-count')"
# The shim collects stderr in a file and replays it after gh exits, so in a merged 2>&1 stream
# stderr lines can follow the stdout lines; the content is compared, not that interleaving.
eq "gh call shapes: stdout+stderr content identical with counting on" "$(printf '%s\n' "$SHAPE_OFF" | sort)" "$(printf '%s\n' "$SHAPE_ON" | sort)"
case "$SHAPE_ON" in *"[git "*) bad "gh call shapes: no gh debug line leaks" ;; *) ok "gh call shapes: no gh debug line leaks" ;; esac
case "$SHAPE_ON" in *"arg1=[two words]"*"arg2=[]"*"arg3=[quote'd]"*) ok "gh call shapes: arguments with spaces, empty and quotes arrive intact" ;; *) bad "gh call shapes: arguments intact (got: $SHAPE_ON)" ;; esac
case "$SHAPE_ON" in *"stdin=[in-data]"*) ok "gh call shapes: stdin reaches gh" ;; *) bad "gh call shapes: stdin reaches gh" ;; esac
case "$SHAPE_ON" in *"H:rc=3"*"I:shape-stderr-text"*) ok "gh call shapes: non-zero exit and stderr text pass through" ;; *) bad "gh call shapes: exit code and stderr text" ;; esac

echo "# the three real scripts: same stdout and exit code with counting on"
# A gh that fails on every call makes each script stop early and deterministically,
# with no GitHub traffic. Counting must not change what they say or how they exit.
check_script() { # name args...
  local name="$1"; shift
  FAKE_FAIL=1 run env HOME="$TMP/home" bash "$SCRIPTS/$name" "$@"
  local o0 e0 r0
  o0="$(cat "$OUT")"; e0="$(cat "$ERR")"; r0=$RC
  FAKE_FAIL=1 run env HOME="$TMP/home" GH_REST_COUNT=1 bash "$SCRIPTS/$name" "$@"
  eq "$name: exit code unchanged with counting on" "$r0" "$RC"
  eq "$name: stdout unchanged with counting on" "$o0" "$(cat "$OUT")"
  eq "$name: stderr unchanged apart from the count line" "$e0" "$(grep -v 'gh-count' "$ERR")"
  eq "$name: reports a count line" "1" "$(grep -c 'gh-count' "$ERR")"
}
check_script merge-gate.sh 1 --reviewer cr
check_script polling-state-gate.sh 1
check_script escalate-review.sh 1

echo
echo "gh-count.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
