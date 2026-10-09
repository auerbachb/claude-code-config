#!/usr/bin/env bash
# /fixpr Step 3b consults the account daily cap last and notes a skip once per HEAD (issue #1812).
# catalog: tests — Runs `/fixpr` Step 3b's real `@cursor review` decision (fixpr-reviewer-triggers.sh, legacy path) against stubs — the daily-cap skip appends its `## Review notes` line once per HEAD, ok/unknown/missing post, and the tier and refused-HEAD skips still win
#
# WHAT IS UNDER TEST
#   Step 3b's bash lives in fixpr-reviewer-triggers.sh since issue #1749. This
#   suite runs that script — the text Claude executes — on a repo with no
#   review policy (the legacy path), with every helper it resolves stubbed
#   beside it except pr-body-review-note.sh, which is the real script, and gh
#   stubbed on PATH. reviewer-activity.sh reports CodeRabbit, Graphite and
#   CodeAnt as already active, so the only post in play is `@cursor review`.
#
#   The premise is asserted first: a script that moved or lost its cursor post
#   fails here loudly instead of passing on an empty program.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/fixpr-reviewer-triggers.sh"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

echo "== premise: Step 3b's script exists and holds the cursor post =="
check_eq "the script posts @cursor review" "yes" \
  "$( [[ -r "$SRC" ]] && grep -qF -- '--body "@cursor review"' "$SRC" && echo yes || echo no )"
if [[ ! -r "$SRC" ]]; then
  echo "== summary: $PASS passed, $((FAIL)) failed =="; exit 1
fi
LEGACY="$(awk '/^if \[\[ "\$TRIGGER_MODE" == "legacy" \]\]; then$/ { f = 1 } f { print } f && /^  exit 0$/ { exit }' "$SRC")"
check_eq "the legacy block was located" "yes" "$( [[ -n "$LEGACY" && "$LEGACY" == *'@cursor review'* ]] && echo yes || echo no )"

echo "== static: the cap is the LAST gate and the note names the pushed HEAD =="
ln_of() { grep -nF -- "$1" <<<"$LEGACY" | head -1 | cut -d: -f1; }
TIER_LN="$(ln_of 'TIER_GATE=$("$BUGBOT_TIER_SH"')"
REFUSED_LN="$(ln_of '"$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$PUSHED_SHA"')"
CAP_LN="$(ln_of 'elif bugbot_cap_over; then')"
check_eq "tier, then refused-HEAD, then the cap" "yes" \
  "$( [[ -n "$TIER_LN" && -n "$REFUSED_LN" && -n "$CAP_LN" && "$TIER_LN" -lt "$REFUSED_LN" && "$REFUSED_LN" -lt "$CAP_LN" ]] && echo yes || echo no )"
check_eq "the note is keyed to \$PUSHED_SHA" "1" "$(grep -cF -- '--head "$PUSHED_SHA" --key bugbot-daily-cap' "$SRC" | tr -d ' ')"
check_eq "the note text is the issue's" "1" \
  "$(grep -cF -- "'BugBot skipped: daily cap (\$%.2f of \$%.2f today)'" "$SRC" | tr -d ' ')"

# ---- stubs ---------------------------------------------------------------------
export HOME="$TMP_HOME"
S="$TMP/scripts"
mkdir -p "$S" "$TMP/work" "$TMP/bin" "$HOME/.claude"
cp "$SRC" "$REPO_ROOT/.claude/scripts/pr-body-review-note.sh" "$S/"
cat > "$S/reviewer-activity.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"coderabbit":true,"graphite":true,"codeant":true}'
EOF
cat > "$S/bugbot-tier-excluded.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [[ -n "${FIXTURE_TIER:-}" ]]; then echo "$FIXTURE_TIER"; exit 0; fi
echo full; exit 1
EOF
cat > "$S/bugbot-refused-head.sh" <<'EOF'
#!/usr/bin/env bash
printf 'refused %s\n' "$*" >> "$CALLS"
[[ -n "${FIXTURE_REFUSED:-}" ]]
EOF
cat > "$S/review-daily-cap.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo "${FIXTURE_RATE:-1.58}"; exit 0; fi
printf 'cap %s\n' "$*" >> "$CALLS"
printf '%s\n' "$FIXTURE_CAP_OUT"
exit "${FIXTURE_CAP_RC:-0}"
EOF
chmod +x "$S"/*.sh
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr comment")
    prev=""
    for a in "$@"; do [[ "$prev" == "--body" ]] && echo "$a" >> "$POSTED"; prev="$a"; done ;;
  "pr view") cat "$GH_BODY" ;;
  "pr edit")
    prev=""
    for a in "$@"; do [[ "$prev" == "--body-file" ]] && cp "$a" "$GH_BODY"; prev="$a"; done ;;
  "api --paginate") echo '[]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CALLS="$TMP/calls" POSTED="$TMP/posted" GH_BODY="$TMP/body.md"
PR_NUMBER=1840
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

over='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.5,"add_usd":1.58,"cap_usd":10,"status":"over"}'
ok='{"platform":"bugbot","date":"2026-10-08","spent_usd":3.16,"add_usd":1.58,"cap_usd":10,"status":"ok"}'
unknown='{"platform":"bugbot","date":"2026-10-08","spent_usd":null,"add_usd":1.58,"cap_usd":10,"status":"unknown"}'

reset() {   # <cap out> <cap rc>
  export FIXTURE_CAP_OUT="$1" FIXTURE_CAP_RC="$2" FIXTURE_TIER="" FIXTURE_REFUSED=""
  : > "$CALLS"; : > "$POSTED"
  printf '## Summary\n\nFixes a thing.\n\n## Test plan\n\n- [ ] it works\n' > "$GH_BODY"
}
STDOUT=""
step3b() {   # <pushed sha>
  STDOUT="$(cd "$TMP/work" && bash "$S/fixpr-reviewer-triggers.sh" "$PR_NUMBER" --repo acme/one \
    --pushed-sha "$1" --pushed-at 2026-10-08T12:00:00Z 2>"$TMP/err")"
}
cursor_posts() { grep -cFx "@cursor review" "$POSTED" | tr -d ' '; }
note_lines() { grep -cF 'BugBot skipped: daily cap ($9.50 of $10.00 today)' "$GH_BODY" | tr -d ' '; }

############################################################################
echo "== over: no @cursor review, and the note lands once across two runs on one HEAD =="
reset "$over" 1
step3b "$SHA_A"
check_eq "no @cursor review" "0" "$(cursor_posts)"
check_eq "nothing else posted either (the other three were active)" "" "$(cat "$POSTED")"
check_eq "the note is in the body" "1" "$(note_lines)"
check_eq "under ## Review notes" "1" "$(grep -c '^## Review notes' "$GH_BODY" | tr -d ' ')"
check_eq "it says so" "yes" "$( [[ "$STDOUT" == *'skipping @cursor review — BugBot skipped: daily cap ($9.50 of $10.00 today)'* ]] && echo yes || echo no )"
check_eq "it ran the legacy path" "yes" "$( [[ "$STDOUT" == *'TRIGGER_MODE=legacy'* ]] && echo yes || echo no )"
step3b "$SHA_A"
check_eq "second run, same HEAD: still exactly one line" "1" "$(note_lines)"
check_eq "  and still no @cursor review" "0" "$(cursor_posts)"
check_eq "the Test plan section is untouched" "- [ ] it works" "$(grep -F -- '- [ ]' "$GH_BODY")"
step3b "$SHA_B"
check_eq "a new HEAD adds its own line" "2" "$(note_lines)"
check_eq "the cap was asked with the --rate figure" "cap bugbot --add-usd 1.58" "$(grep '^cap ' "$CALLS" | head -1)"

echo "== a garbled --rate answer is never passed through: --add-usd 0 =="
reset "$over" 1
FIXTURE_RATE='1.58; rm -rf /' step3b "$SHA_A"
check_eq "the cap was asked with 0" "cap bugbot --add-usd 0" "$(grep '^cap ' "$CALLS" | head -1)"

echo "== ok: posts, writes nothing to the body =="
reset "$ok" 0
step3b "$SHA_A"
check_eq "@cursor review posted" "1" "$(cursor_posts)"
check_eq "no note" "0" "$(grep -c 'Review notes' "$GH_BODY" | tr -d ' ')"

echo "== unknown: posts and says the cap is unknown =="
reset "$unknown" 0
step3b "$SHA_A"
check_eq "@cursor review posted" "1" "$(cursor_posts)"
check_eq "it says so" "yes" "$( [[ "$STDOUT" == *"BugBot daily cap unknown"* ]] && echo yes || echo no )"
echo "== over with a disagreeing exit code: posts =="
reset "$over" 0
step3b "$SHA_A"
check_eq "@cursor review posted" "1" "$(cursor_posts)"

echo "== the helper is missing: posts and says so =="
reset "$over" 1
mv "$S/review-daily-cap.sh" "$TMP/cap.bak"
step3b "$SHA_A"
mv "$TMP/cap.bak" "$S/review-daily-cap.sh"
check_eq "@cursor review posted" "1" "$(cursor_posts)"
check_eq "DEGRADED line" "yes" "$( [[ "$STDOUT" == *"DEGRADED: review-daily-cap.sh not found"* ]] && echo yes || echo no )"

echo "== the note helper is missing: still skips, warns, body untouched =="
reset "$over" 1
mv "$S/pr-body-review-note.sh" "$TMP/note.bak"
step3b "$SHA_A"
mv "$TMP/note.bak" "$S/pr-body-review-note.sh"
check_eq "no @cursor review" "0" "$(cursor_posts)"
check_eq "warns" "yes" "$(grep -q 'could not record the daily-cap skip' "$TMP/err" && echo yes || echo no)"

############################################################################
echo "== precedence: the tier skip wins; the cap is never asked =="
reset "$over" 1
export FIXTURE_TIER=ci-only
step3b "$SHA_A"
check_eq "no @cursor review" "0" "$(cursor_posts)"
check_eq "no cap call" "0" "$(grep -c '^cap ' "$CALLS" | tr -d ' ')"
check_eq "no note (the tier, not the cap, skipped)" "0" "$(note_lines)"
check_eq "the tier helper was asked about this repo" "$PR_NUMBER --repo acme/one" "$(grep -v '^refused\|^cap' "$CALLS" | head -1)"
echo "== precedence: a refused HEAD wins; the cap is never asked =="
reset "$over" 1
export FIXTURE_REFUSED=1
step3b "$SHA_A"
check_eq "no @cursor review" "0" "$(cursor_posts)"
check_eq "no cap call" "0" "$(grep -c '^cap ' "$CALLS" | tr -d ' ')"
check_eq "the refusal guard was asked about the PUSHED SHA" "refused $PR_NUMBER $SHA_A" "$(grep '^refused ' "$CALLS")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: fixpr Step 3b daily-cap tests passed"
