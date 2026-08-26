#!/usr/bin/env bash
# merge-gate-json-escaping.test.sh — Regression tests for issue #1219:
# merge-gate.sh must not ship control characters in its JSON, and must build
# every part of that JSON with jq rather than by string-concatenation.
#
# The trace this comes from (PR #1218, HEAD baea515):
#
#   $ .claude/scripts/merge-gate.sh 1218 | jq '.met'
#   jq: parse error: Invalid string: control characters from U+0000 through
#       U+001F must be escaped at line 5, column 2
#
# The gate's own stdout was valid JSON the whole time. What broke was the READ:
# `capability_failure_text` embeds a bot comment body verbatim, so the payload
# carried `\n` escape sequences, and **zsh's `echo` expands backslash escapes by
# default** — turning them into raw newlines before jq ever parsed. Replaying the
# real PR #1218 payloads reproduces the error byte-for-byte under
# `zsh -c 'echo "$J" | jq'` and not under bash's `echo` or `printf '%s'`.
#
# So the fix is to stop shipping control characters at all: with no `\n` in the
# document there is nothing for a shell `echo` to expand.
#
# `printf '%b'` stands in for zsh's `echo` below — same backslash expansion,
# available in bash, so the test needs no zsh on the CI runner.
#
# Cases:
#   (a) a capability-failure body with newlines, tabs and quotes
#       -> no control character survives in ANY emitted string
#   (b) the same output survives shell backslash expansion -> still parses
#   (c) the raw output parses (no-regression guard; true before and after)
#   (d) the snippet stays useful — quotes preserved, newlines folded to spaces
#   (e) backslashes: the document stays valid JSON, and the boundary is stated
#       out loud — a literal backslash still round-trips as `\\`, so `echo` is
#       still the wrong way to read this output; use printf '%s' or a herestring
#   (f) a check-run name containing a newline yields ONE missing[] entry, not
#       two — `jq -R .` split it per line
#   (g) a non-OPEN PR state containing a quote and a newline still emits valid
#       JSON — the hand-built `"[\"PR #N is $PR_STATE — not open\"]"` literal
#       made jq reject its own --argjson and emit nothing at all
#   (h) review-substance.sh is clean AT THE SOURCE. escalate-review.sh pipes the
#       evaluator straight into jq without going through merge-gate.sh, so the
#       emit_json scrub never runs for it — the field has to be clean where it is
#       built, not only where merge-gate re-emits it
#
# Only `gh` is stubbed; merge-gate.sh, review-substance.sh, ci-status.sh and
# check-runs-dedup.sh are the real scripts.
#
# Run from repo root: bash .claude/scripts/tests/merge-gate-json-escaping.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/merge-gate.sh"
EVAL_SUT="$REPO_ROOT/.claude/scripts/review-substance.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: '$1', got: '$2')"; fi
}
check_contains() { # needle haystack label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) bad "$3 (missing '$1' in: $2)" ;;
  esac
}

HEAD_SHA="396ced5aabbccddeeff001122334455667788990"
COMMIT_TS="2026-08-21T21:15:34Z"
APPROVE_TS="2026-08-21T21:15:50Z"

# --- Fake gh stub -------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    echo "solouser"; exit 0 ;;
  *"pr view "*headRefOid*)
    jq -cn --arg sha "$HEAD_SHA" --arg st "${FAKE_PR_STATE:-OPEN}" \
      '{number:1, state:$st, headRefOid:$sha, baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:"solouser", type:"User"}}'
    exit 0 ;;
  *"git/commits/"*)
    jq -cn --arg d "$FAKE_COMMIT_TS" '{committer:{date:$d}}'; exit 0 ;;
  *check-runs*)
    printf '%s' "${FAKE_CHECK_RUNS:-}"; exit 0 ;;
  *pulls/*/reviews*)
    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *pulls/*/comments*)
    printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *issues/*/comments*)
    printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*)
    # Branch-protection required contexts (issue #1361). Default is a 404, which
    # combined with the unprotected branch object below resolves to "no required
    # status checks" — so every pre-#1361 expectation in this file is unchanged.
    # FAKE_REQUIRED_STATUS_CHECKS supplies the endpoint payload;
    # FAKE_BRANCH_PROTECTED=true marks the base branch protected.
    if [[ -n "${FAKE_REQUIRED_STATUS_CHECKS:-}" ]]; then
      printf '%s' "${FAKE_REQUIRED_STATUS_CHECKS}"; exit 0
    fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    if [[ -n "${FAKE_BRANCH_JSON:-}" ]]; then
      printf '%s' "${FAKE_BRANCH_JSON}"; exit 0
    fi
    jq -cn --arg p "${FAKE_BRANCH_PROTECTED:-false}" \
      '{name:"main", protected:($p == "true"),
        protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*)
    echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export HEAD_SHA
export FAKE_COMMIT_TS="$COMMIT_TS"
# Marked for export once, then assigned plainly per case: `export VAR="$(cmd)"`
# would mask the command substitution's exit status (SC2155).
export FAKE_REVIEWS FAKE_PR_COMMENTS FAKE_ISSUE_COMMENTS FAKE_CHECK_RUNS FAKE_PR_STATE
FAKE_REVIEWS='[]'; FAKE_PR_COMMENTS='[]'; FAKE_ISSUE_COMMENTS='[]'; FAKE_PR_STATE='OPEN'
GREEN_CHECKS="$(jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
                  completed_at:"2026-08-21T21:20:00Z",check_suite:{id:1},app:{slug:"gha",id:1}}]}')"
FAKE_CHECK_RUNS="$GREEN_CHECKS"

# --- Fixture builders ---------------------------------------------------
approval() { # <login> <body> [submitted_at]
  jq -cn --arg l "$1" --arg b "$2" --arg sha "$HEAD_SHA" --arg t "${3:-$APPROVE_TS}" \
    '[{user:{login:$l,type:"Bot"}, commit_id:$sha, state:"APPROVED", body:$b, submitted_at:$t}]'
}
convo() { # <login> <body> <created_at>
  jq -cn --args '[ $ARGS.positional | _nwise(3)
                   | {user:{login:.[0],type:"Bot"}, body:.[1], created_at:.[2], updated_at:.[2]} ]' -- "$@"
}

# No case here needs extra flags — the fixtures vary through the FAKE_* env vars.
run_gate() {
  "$SUT" 1 --reviewer cr 2>"$TMP/err.txt"
}

# Every string anywhere in the decoded document, counted for control characters.
# `..` walks the whole tree, so this covers fields that do not exist yet.
control_char_strings() { # <json text>
  printf '%s' "$1" | jq -c '[.. | strings | select(test("[[:cntrl:]]"))]' 2>/dev/null || echo 'JQ_FAILED'
}

# A CodeRabbit capability-failure notice shaped like the real one: HTML-comment
# preamble, blank lines, a tab, and quotes. Deliberately NO backslash — case (e)
# owns that boundary.
CR_FAIL_BODY=$'<!-- This is an auto-generated reply by CodeRabbit -->\n\n> [!WARNING]\n> Review rate limit exceeded.\n\tPlease wait before requesting another "full review".\n\nSee the "docs" for details.'

echo "=== (a) no control character survives into any emitted string ==="
FAKE_REVIEWS="$(approval "coderabbitai[bot]" "" "2026-08-21T21:15:50Z")"
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" "$CR_FAIL_BODY" "2026-08-21T21:15:40Z")"
OUT="$(run_gate)"
check_eq "[]" "$(control_char_strings "$OUT")" "(a) no emitted string contains a control character"
check_eq "coderabbitai[bot]" "$(printf '%s' "$OUT" | jq -r '.review_evidence.capability_failed[0]')" \
  "(a) the fixture really does reach the capability-failure path"

echo "=== (b) the output survives shell backslash expansion (zsh echo) ==="
# printf '%b' performs the same expansion zsh's `echo` does. Before the fix the
# embedded \n became a raw newline here and jq rejected the document with
# 'control characters from U+0000 through U+001F must be escaped'.
if printf '%b' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "(b) backslash-expanded output still parses"
else
  bad "(b) backslash-expanded output no longer parses: $(printf '%b' "$OUT" | jq -e . 2>&1 | head -1)"
fi

echo "=== (c) the raw output parses (no-regression guard) ==="
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "(c) raw output is valid JSON"
else
  bad "(c) raw output is not valid JSON"
fi

echo "=== (d) the diagnostic snippet stays useful ==="
CFT="$(printf '%s' "$OUT" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].capability_failure_text')"
check_contains 'Review rate limit exceeded.' "$CFT" "(d) the human-readable text is preserved"
check_contains '"full review"' "$CFT" "(d) quotes are preserved verbatim"
check_contains 'CodeRabbit --> ' "$CFT" "(d) newlines are folded to spaces, not deleted"

echo "=== (e) a literal backslash keeps the document valid JSON ==="
# Boundary, stated out loud: normalizing control characters does NOT make the
# payload safe to read with `echo`. A literal backslash still ships as `\\`, and
# a shell that expands escapes will corrupt it. Consumers must use printf '%s'
# or a herestring — see the merge-gate.sh header.
FAKE_ISSUE_COMMENTS="$(convo "coderabbitai[bot]" \
  $'Rate limit exceeded.\nPath C:\\Users\\bot and a "quote".' "2026-08-21T21:15:40Z")"
OUT_BS="$(run_gate)"
if printf '%s' "$OUT_BS" | jq -e . >/dev/null 2>&1; then
  ok "(e) a backslash-bearing body still emits valid JSON"
else
  bad "(e) a backslash-bearing body broke the document"
fi
check_eq "[]" "$(control_char_strings "$OUT_BS")" "(e) still no control characters"
check_contains 'C:\Users\bot' \
  "$(printf '%s' "$OUT_BS" | jq -r '.review_evidence.reviewers["coderabbitai[bot]"].capability_failure_text')" \
  "(e) the backslashes themselves are preserved"

echo "=== (f) a newline in a check-run name yields ONE missing[] entry ==="
FAKE_ISSUE_COMMENTS='[]'
FAKE_REVIEWS='[]'
FAKE_CHECK_RUNS="$(jq -cn '{check_runs:[{id:1,name:"lint\nsecond line",status:"in_progress",
                    conclusion:null,completed_at:null,check_suite:{id:1},app:{slug:"gha",id:1}}]}')"
OUT_CI="$(run_gate)"
if printf '%s' "$OUT_CI" | jq -e . >/dev/null 2>&1; then
  ok "(f) output with a multi-line check-run name is valid JSON"
else
  bad "(f) output with a multi-line check-run name is not valid JSON"
fi
check_eq "1" "$(printf '%s' "$OUT_CI" | jq '[.missing[] | select(test("incomplete check-run"))] | length')" \
  "(f) the CI message stays one array element"
# The count catches the split independently of the prose: `jq -R .` turned two
# reasons into three array entries by breaking the check-run name across lines.
check_eq "2" "$(printf '%s' "$OUT_CI" | jq '.missing | length')" \
  "(f) missing[] has one element per reason, not one per line"
check_contains "lint second line" \
  "$(printf '%s' "$OUT_CI" | jq -r '.missing | join(" | ")')" \
  "(f) the whole check-run name survives in that one element"
check_eq "[]" "$(control_char_strings "$OUT_CI")" "(f) no control characters in missing[]"
FAKE_CHECK_RUNS="$GREEN_CHECKS"

echo "=== (g) a hostile PR state still emits valid JSON on the error path ==="
# Exercises the hand-built `"[\"PR #N is $PR_STATE — not open\"]"` literal. Before
# the fix, jq rejected its own --argjson and merge-gate.sh emitted NOTHING while
# still exiting 3 — a caller reading stdout saw an empty string, not an error.
FAKE_PR_STATE=$'CLO"SED\nEXTRA'
OUT_ST="$(run_gate)"; ST_RC=$?
check_eq "3" "$ST_RC" "(g) the not-open path still exits 3"
if printf '%s' "$OUT_ST" | jq -e . >/dev/null 2>&1; then
  ok "(g) the not-open payload is valid JSON"
else
  bad "(g) the not-open payload is not valid JSON (got: '${OUT_ST:0:120}')"
fi
check_contains "not open" "$(printf '%s' "$OUT_ST" | jq -r '.missing | join(" | ")' 2>/dev/null || echo "")" \
  "(g) the reason survives into missing[]"
check_eq "[]" "$(control_char_strings "$OUT_ST")" "(g) no control characters on the error path"
FAKE_PR_STATE='OPEN'

echo "=== (h) review-substance.sh emits no control characters on its own ==="
# Driven directly, not through merge-gate.sh: escalate-review.sh reads this
# evaluator's stdout itself, so merge-gate's emit-time scrub never covers it.
EVAL_OUT="$(jq -cn --arg sha "$HEAD_SHA" --arg push "$COMMIT_TS" --arg b "$CR_FAIL_BODY" \
  '{head_sha: $sha, push_ts: $push,
    reviews: [{user:{login:"coderabbitai[bot]",type:"Bot"}, commit_id:$sha,
               state:"APPROVED", body:"", submitted_at:"2026-08-21T21:15:50Z"}],
    pr_comments: [],
    issue_comments: [{user:{login:"coderabbitai[bot]",type:"Bot"}, body:$b,
                      created_at:"2026-08-21T21:15:40Z", updated_at:"2026-08-21T21:15:40Z"}]}' \
  | "$EVAL_SUT" 2>/dev/null)"
check_eq "coderabbitai[bot]" "$(printf '%s' "$EVAL_OUT" | jq -r '.capability_failed[0]')" \
  "(h) the evaluator fixture reaches the capability-failure path"
check_eq "[]" "$(control_char_strings "$EVAL_OUT")" \
  "(h) the evaluator's own output carries no control characters"
if printf '%b' "$EVAL_OUT" | jq -e . >/dev/null 2>&1; then
  ok "(h) evaluator output survives backslash expansion"
else
  bad "(h) evaluator output does not survive backslash expansion"
fi

echo
echo "merge-gate-json-escaping: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
