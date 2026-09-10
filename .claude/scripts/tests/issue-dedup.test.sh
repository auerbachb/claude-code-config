#!/usr/bin/env bash
# issue-dedup.test.sh — unit tests for issue-dedup.sh (issue #652)
# catalog: tests — Tests for `issue-dedup.sh`
#
# The load-bearing case is the regression that motivated the helper: issue #647
# ("polling-state-gate.sh falsely refuses…") restated issue #638's second
# acceptance criterion while sharing almost no TITLE words. A title-only search
# — what /wrap and /issue-maker both did before #652 — could not see it, so the
# fixtures below are abbreviated copies of those two real bodies.
#
# Also covers: no-match files rather than suppresses, closed issues rank below
# open ones, --exclude, stopword-only keywords, boundary-aware term matching,
# and usage/environment errors.
#
# Runs hermetically: temp HOME, stubbed `gh`. No network, no git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEDUP="$SCRIPT_DIR/../issue-dedup.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2], got [$3]"; fi
}

# ---- fixtures ---------------------------------------------------------------
# Abbreviated but faithful: the overlap between these two bodies lives entirely
# below the title line, which is the whole point of the regression.
cat > "$WORK/open.json" <<'JSON'
[
  {
    "number": 638,
    "title": "Scope session-state.json per repo — PR numbers collide across projects",
    "url": "https://github.com/o/r/issues/638",
    "state": "OPEN",
    "body": "Every repo and every session share one orchestration file: ~/.claude/session-state.json. The same single-value assumption bites at the top level. .root_repo is one scalar for the whole file, so it names whichever repo wrote last. In practice it is usually pointing somewhere else, which is why polling-state-gate.sh refuses with a wrong checkout error that is not real. Acceptance: .root_repo is per-repo scope rather than a single global scalar, or is removed in favor of the caller passing repo context explicitly. Every consumer is updated: polling-state-gate.sh, merge-gate.sh, infer-pr.sh."
  },
  {
    "number": 611,
    "title": "Add a retry cap to the CodeRabbit trigger loop",
    "url": "https://github.com/o/r/issues/611",
    "state": "OPEN",
    "body": "The explicit full review trigger has no ceiling per PR per hour beyond the documented convention. Add an enforced cap in cr-review-hourly.sh."
  }
]
JSON

cat > "$WORK/closed.json" <<'JSON'
[
  {
    "number": 512,
    "title": "Session state root_repo handling for worktrees",
    "url": "https://github.com/o/r/issues/512",
    "state": "CLOSED",
    "body": "Early pass at root_repo resolution inside worktrees for polling-state-gate.sh. Superseded."
  }
]
JSON

# `gh` stub: serves the fixture matching the --state argument.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
state="open"
for a in "\$@"; do
  case "\$prev" in --state) state="\$a" ;; esac
  prev="\$a"
done
case "\$state" in
  open)   cat "$WORK/open.json" ;;
  closed) cat "$WORK/closed.json" ;;
  *)      echo "[]" ;;
esac
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

run() {
  # run <keywords> [extra args...] -> sets OUT and RC
  local kw="$1"; shift
  set +e
  OUT=$("$DEDUP" "$kw" "$@" 2>/dev/null)
  RC=$?
  set -e
}

top_number()   { printf '%s' "$OUT" | jq -r '.[0].number // empty'; }
top_coverage() { printf '%s' "$OUT" | jq -r '.[0].coverage // 0'; }
has_number()   { printf '%s' "$OUT" | jq -e --argjson n "$1" 'any(.[]; .number == $n)' >/dev/null 2>&1; }

echo "== regression: the #647 finding must surface #638 (body-only overlap) =="
# Keywords a /wrap sweep would derive from the #647 finding. Note that none of
# them appear in #638's title.
run "polling-state-gate.sh root_repo session-state.json concurrent scoping"
assert_eq "exit 0 (candidate found)" "0" "$RC"
assert_eq "top candidate is #638" "638" "$(top_number)"
if awk -v c="$(top_coverage)" 'BEGIN { exit !(c >= 0.6) }'; then
  ok "coverage >= 0.6 (clears the strong-match numeric floor)"
else
  fail "coverage >= 0.6 — got $(top_coverage)"
fi
# Guard the premise: a title-only search would have missed it.
if grep -qi "polling-state-gate" \
     <<<"$(jq -r '.[] | select(.number == 638) | .title' "$WORK/open.json")"; then
  fail "fixture premise broken — #638's title mentions polling-state-gate"
else
  ok "premise holds: #638's title shares none of the finding's distinctive terms"
fi

echo "== no match: an unrelated finding files rather than suppressing =="
run "greptile severity badge parsing"
assert_eq "exit 1 (no candidate)" "1" "$RC"
assert_eq "empty JSON array" "[]" "$(printf '%s' "$OUT" | jq -c '.')"

echo "== stopword-only keywords degrade to 'file', never to 'duplicate found' =="
run "the and for with this issue file"
assert_eq "exit 1 (no usable terms)" "1" "$RC"
assert_eq "empty JSON array" "[]" "$(printf '%s' "$OUT" | jq -c '.')"

echo "== closed issues are surfaced but never outrank an open match =="
run "root_repo polling-state-gate.sh worktrees session-state.json"
assert_eq "exit 0" "0" "$RC"
assert_eq "open #638 outranks closed #512" "638" "$(top_number)"
if has_number 512; then
  ok "closed #512 still surfaced as context"
else
  fail "closed #512 should appear among candidates"
fi
assert_eq "closed candidate carries state CLOSED" "CLOSED" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.number == 512) | .state')"

echo "== --exclude drops issues this run already filed =="
run "polling-state-gate.sh root_repo session-state.json concurrent scoping" --exclude 638
if has_number 638; then
  fail "#638 should have been excluded"
else
  ok "#638 excluded"
fi

echo "== term matching is boundary-aware =="
# Alphanumerics and `_` bind: `poll` must not match `polling` (the fixture's only
# occurrence), so a lone `poll` yields no candidate rather than a spurious one.
run "poll"
assert_eq "'poll' does not match 'polling'" "1" "$RC"
# `.` and `-` separate, so a scoped field name still matches its bare identifier —
# this is precisely the #638/#647 overlap the helper has to see.
run "root_repo"
assert_eq "'root_repo' matches inside '.root_repo'" "0" "$RC"
assert_eq "and resolves to #638" "638" "$(top_number)"

echo "== --max-results caps the list =="
run "root_repo polling-state-gate.sh session-state.json" --max-results 1
assert_eq "exactly one candidate" "1" "$(printf '%s' "$OUT" | jq 'length')"

echo "== gh warnings on stderr must not corrupt the JSON parse =="
# gh can print deprecation/auth notices on stderr while still succeeding. If
# those lines were folded into stdout the JSON parse would fail and the caller
# would see exit 4 instead of a real candidate list.
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
echo "warning: gh version 2.48.0 is out of date" >&2
state="open"
for a in "\$@"; do
  case "\$prev" in --state) state="\$a" ;; esac
  prev="\$a"
done
case "\$state" in
  open)   cat "$WORK/open.json" ;;
  closed) cat "$WORK/closed.json" ;;
  *)      echo "[]" ;;
esac
EOF
chmod +x "$WORK/bin/gh"
run "polling-state-gate.sh root_repo session-state.json concurrent scoping"
assert_eq "stderr noise does not break the scan" "0" "$RC"
assert_eq "still resolves #638" "638" "$(top_number)"

echo "== a failing gh reports exit 4, never exit 1 ('no duplicates') =="
# The distinction matters: exit 1 tells the caller it is safe to file without a
# duplicate note, so an outage must never be reported as a clean search.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "error: could not connect to api.github.com" >&2
exit 1
EOF
chmod +x "$WORK/bin/gh"
run "polling-state-gate.sh root_repo session-state.json"
assert_eq "gh failure → exit 4" "4" "$RC"
assert_eq "still emits parseable JSON" "[]" "$(printf '%s' "$OUT" | jq -c '.')"

echo "== usage errors =="
set +e
"$DEDUP" >/dev/null 2>&1; rc_noargs=$?
"$DEDUP" "keywords here" --bogus >/dev/null 2>&1; rc_badopt=$?
"$DEDUP" "keywords here" --open-limit abc >/dev/null 2>&1; rc_badnum=$?
"$DEDUP" --help >/dev/null 2>&1; rc_help=$?
set -e
assert_eq "no args → exit 2" "2" "$rc_noargs"
set +e
"$DEDUP" "keywords here" --min-coverage 1.5 >/dev/null 2>&1; rc_range=$?
set -e
assert_eq "--min-coverage above 1 → exit 2" "2" "$rc_range"
# A trailing bare flag must be a usage error, not a `shift 2` failure under
# set -e — that exits 1, which callers read as "searched, found nothing".
for flag in --repo --open-limit --closed-days --closed-limit --min-coverage --max-results --exclude; do
  set +e
  "$DEDUP" "some keywords" "$flag" >/dev/null 2>&1; rc_missing=$?
  set -e
  assert_eq "$flag with no value → exit 2" "2" "$rc_missing"
done
assert_eq "unknown option → exit 2" "2" "$rc_badopt"
assert_eq "non-numeric limit → exit 2" "2" "$rc_badnum"
assert_eq "--help → exit 0" "0" "$rc_help"

# ---- regression #696: fix 1 — score-first ranking ----------------------------
echo "== regression #696: high-score closed beats low-score open (score-first ranking) =="
# Before the fix, (state=="OPEN") led the sort key, so every open issue
# outranked every closed one regardless of score.  A perfect-1.0 closed match
# was pushed past position 5 by five lower-scoring open issues and silently
# dropped by --max-results 5 — the #638/#647 mechanism.
# After the fix, score is the primary key; OPEN is only the tiebreak at equal
# score, matching what the sort comment already promised.
#
# Fixture: 5 open issues each matching 2/5 terms (coverage 0.40, score 0.40),
# plus 1 closed issue matching all 5 (coverage 1.0, score 1.0).
cat > "$WORK/open_rank.json" <<'JSON'
[
  {"number": 101, "title": "Unrelated issue one",   "url": "https://github.com/o/r/issues/101", "state": "OPEN",   "body": "xyzzy quuxbaz"},
  {"number": 102, "title": "Unrelated issue two",   "url": "https://github.com/o/r/issues/102", "state": "OPEN",   "body": "xyzzy quuxbaz"},
  {"number": 103, "title": "Unrelated issue three", "url": "https://github.com/o/r/issues/103", "state": "OPEN",   "body": "xyzzy quuxbaz"},
  {"number": 104, "title": "Unrelated issue four",  "url": "https://github.com/o/r/issues/104", "state": "OPEN",   "body": "xyzzy quuxbaz"},
  {"number": 105, "title": "Unrelated issue five",  "url": "https://github.com/o/r/issues/105", "state": "OPEN",   "body": "xyzzy quuxbaz"}
]
JSON
cat > "$WORK/closed_rank.json" <<'JSON'
[
  {"number": 999, "title": "Another unrelated", "url": "https://github.com/o/r/issues/999",
   "state": "CLOSED", "body": "xyzzy quuxbaz frobble wibble narf"}
]
JSON
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
state="open"
for a in "\$@"; do case "\$prev" in --state) state="\$a" ;; esac; prev="\$a"; done
case "\$state" in
  open)   cat "$WORK/open_rank.json" ;;
  closed) cat "$WORK/closed_rank.json" ;;
  *)      echo "[]" ;;
esac
EOF
chmod +x "$WORK/bin/gh"
run "xyzzy quuxbaz frobble wibble narf"
assert_eq "exit 0 (candidates found)" "0" "$RC"
assert_eq "closed #999 (score 1.0) ranks first over five open issues (score 0.40)" "999" "$(top_number)"
if has_number 101; then
  ok "low-score open #101 still surfaces (not suppressed)"
else
  fail "open #101 should still surface"
fi

echo "== regression #696: open still wins at equal score (tiebreak preserved) =="
# This guards the /wrap use-case: a closed issue does not suppress an open one
# at the same match quality, because the open one can still absorb a comment.
cat > "$WORK/open_tie.json" <<'JSON'
[
  {"number": 200, "title": "Open full match", "url": "https://github.com/o/r/issues/200",
   "state": "OPEN", "body": "xyzzy quuxbaz frobble wibble narf"}
]
JSON
cat > "$WORK/closed_tie.json" <<'JSON'
[
  {"number": 201, "title": "Closed full match", "url": "https://github.com/o/r/issues/201",
   "state": "CLOSED", "body": "xyzzy quuxbaz frobble wibble narf"}
]
JSON
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
state="open"
for a in "\$@"; do case "\$prev" in --state) state="\$a" ;; esac; prev="\$a"; done
case "\$state" in
  open)   cat "$WORK/open_tie.json" ;;
  closed) cat "$WORK/closed_tie.json" ;;
  *)      echo "[]" ;;
esac
EOF
chmod +x "$WORK/bin/gh"
run "xyzzy quuxbaz frobble wibble narf"
assert_eq "exit 0" "0" "$RC"
assert_eq "open #200 ranks first at equal score (tiebreak preserved)" "200" "$(top_number)"
if has_number 201; then
  ok "closed #201 also surfaces"
else
  fail "closed #201 should also surface"
fi

# ---- regression #696: fix 2 — numeric tokens kept ---------------------------
echo "== regression #696: numeric token '403' contributes to terms_matched and coverage =="
# Before the fix, t.isdigit() silently dropped '403' from the term set.
# For keywords "codeant 403 re-authenticate daily cap":
#   OLD (4 terms, 403 gone): issue matching only "codeant" scores 1/4 = 0.25 — below
#     the 0.34 floor, filtered out.
#   NEW (5 terms, 403 kept): same issue also matches "403", scoring 2/5 = 0.40 —
#     above the floor, surfaces.
# The len < 3 guard already drops noisy short numbers; removing isdigit() only
# affects identifiers of length ≥ 3 such as error codes and PR/issue numbers.
cat > "$WORK/open_403.json" <<'JSON'
[]
JSON
cat > "$WORK/closed_403.json" <<'JSON'
[
  {"number": 643, "title": "Unexpected error from review CLI",
   "url": "https://github.com/o/r/issues/643", "state": "CLOSED",
   "body": "codeant 403 error response unauthorized"}
]
JSON
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
state="open"
for a in "\$@"; do case "\$prev" in --state) state="\$a" ;; esac; prev="\$a"; done
case "\$state" in
  open)   cat "$WORK/open_403.json" ;;
  closed) cat "$WORK/closed_403.json" ;;
  *)      echo "[]" ;;
esac
EOF
chmod +x "$WORK/bin/gh"
# Keywords produce 5 terms: codeant, 403, re-authenticate, daily, cap.
# Issue #643 body matches "codeant" and "403" → 2/5 = 0.40 ≥ 0.34 floor.
run "codeant 403 re-authenticate daily cap"
assert_eq "exit 0 (numeric token raises coverage above 0.34 floor)" "0" "$RC"
if printf '%s' "$OUT" | jq -e '.[0].terms_matched | contains(["403"])' >/dev/null 2>&1; then
  ok "'403' appears in terms_matched"
else
  fail "'403' missing from terms_matched"
fi
if awk -v c="$(printf '%s' "$OUT" | jq -r '.[0].coverage // 0')" \
       'BEGIN { exit !(c >= 0.34) }'; then
  ok "coverage is at or above the 0.34 floor (numeric token contributed)"
else
  fail "coverage below 0.34 — got $(printf '%s' "$OUT" | jq -r '.[0].coverage // 0')"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
