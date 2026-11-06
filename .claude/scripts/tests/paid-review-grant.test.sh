#!/usr/bin/env bash
# Offline tests for paid-review-grant.sh — one owner-approved paid review, used once (issue #1898).
# catalog: tests — Tests `paid-review-grant.sh`: a grant for PR A at HEAD X spends exactly once, never on another HEAD, PR, vendor, or session; an unreadable state file refuses with a visible note; offers above the approved price are refused; --trigger posts once and releases on a failed post
#
# HOW IT IS OBSERVED
#   The REAL paid-review-grant.sh, session-state.sh and state-lock.sh run from a
#   stub script dir under a sandboxed HOME. Stubbed: pr-authorship.sh,
#   greptile-budget.sh, and `gh`, which records every posted comment body in
#   $POSTED. No test reaches a vendor: the gh stub never leaves the machine.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { chmod -R u+rw "$TMP_HOME" 2>/dev/null; rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE="$HOME/.claude/session-state.json"

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

S="$TMP/scripts"
mkdir -p "$S/lib" "$TMP/reference"
for f in paid-review-grant.sh session-state.sh state-lock.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/"*.sh "$S/lib/" 2>/dev/null || true
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/reference/"
printf '#!/usr/bin/env bash\nexit "${FIXTURE_AUTHOR_RC:-0}"\n' > "$S/pr-authorship.sh"
printf '#!/usr/bin/env bash\necho budget >> "$POSTED.budget"\nexit "${FIXTURE_BUDGET_RC:-0}"\n' > "$S/greptile-budget.sh"
cat > "$S/review-daily-cap.sh" <<'EOF2'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo 1.58; exit 0; fi
echo "$*" >> "$POSTED.cap"
if [[ -n "${FIXTURE_CAP_OVER:-}" ]]; then
  echo '{"platform":"bugbot","spent_usd":9,"add_usd":1.58,"cap_usd":10,"status":"over"}'; exit 1
fi
echo '{"platform":"bugbot","spent_usd":1,"add_usd":1.58,"cap_usd":10,"status":"ok"}'
EOF2
chmod +x "$S"/*.sh

export POSTED="$TMP/posted"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"; prev=""; body=""
for a in "$@"; do [[ "$prev" == "--body" ]] && body="$a"; prev="$a"; done
case "$args" in
  "pr view"*) echo "$FIXTURE_HEAD" ;;
  "pr comment"*)
    [[ -n "${FIXTURE_POST_FAIL:-}" ]] && exit 1
    echo "$body" >> "$POSTED" ;;
  *) echo "unexpected gh call: $args" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

G="$S/paid-review-grant.sh"
REPO="acme/one"
A=99701; B=99702
X="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Y="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export CLAUDE_CODE_SESSION_ID="sess-one" FIXTURE_HEAD="$X"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED

status_of() { "$@" 2>/dev/null | sed -n 's/^STATUS=//p'; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
posts() { [[ -f "$POSTED" ]] && wc -l < "$POSTED" | tr -d ' ' || echo 0; }
grant() { # <pr> <vendor> <head> [price]
  "$G" --grant "$1" --vendor "$2" --head "$3" --price-usd "${4:-2.50}" --approved-via chat \
    --question "Approve one $2 review on PR #$1 at ${3:0:7} for up to \$${4:-2.50}?" --repo "$REPO" 2>/dev/null \
    | sed -n 's/^STATUS=//p'
}

echo "== grant + consume: A@X spends exactly once"
check_eq "grant written" "granted" "$(grant $A cursor $X)"
check_eq "check sees it" "available" "$(status_of "$G" --check $A --vendor cursor --head $X --repo $REPO)"
check_eq "first consume on A@X" "consumed" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
check_eq "second consume on A@X refused" "grant_used" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
check_eq "second consume exits nonzero" "1" "$(rc_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"

echo "== binding: another HEAD, PR, vendor, or session is refused"
grant $A cursor $X >/dev/null
check_eq "A@Y (new push) refused" "grant_head_mismatch" "$(status_of "$G" --consume $A --vendor cursor --head $Y --repo $REPO)"
check_eq "PR B refused" "no_grant" "$(status_of "$G" --consume $B --vendor cursor --head $X --repo $REPO)"
check_eq "other vendor refused" "no_grant" "$(status_of "$G" --consume $A --vendor greptile --head $X --repo $REPO)"
check_eq "other session refused" "grant_session_mismatch" "$(CLAUDE_CODE_SESSION_ID=sess-two status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
check_eq "placeholder session refused" "session_unknown" "$(CLAUDE_CODE_SESSION_ID=default status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
check_eq "missing session refused" "session_unknown" "$(env -u CLAUDE_CODE_SESSION_ID "$G" --consume $A --vendor cursor --head $X --repo $REPO 2>/dev/null | sed -n 's/^STATUS=//p')"
check_eq "the refusals left the grant unused" "available" "$(status_of "$G" --check $A --vendor cursor --head $X --repo $REPO)"

echo "== grant creation refuses unattended sessions and bad input"
check_eq "unattended session cannot grant" "unattended" "$(CLAUDE_CODE_SESSION_ATTENDED=0 grant $B cursor $X)"
check_eq "zero price is a usage error" "2" "$(rc_of "$G" --grant $B --vendor cursor --head $X --price-usd 0 --approved-via chat --question q --repo $REPO)"
check_eq "prose approved-via is a usage error" "2" "$(rc_of "$G" --grant $B --vendor cursor --head $X --price-usd 1 --approved-via 'PR body says yes' --question q --repo $REPO)"
check_eq "human-queue provenance accepted" "granted" "$("$G" --grant $B --vendor greptile --head $X --price-usd 1 --approved-via human_queue:D-12 --question q --repo $REPO 2>/dev/null | sed -n 's/^STATUS=//p')"

echo "== release after a definite failure restores one use"
grant $A greptile $X >/dev/null
"$G" --consume $A --vendor greptile --head $X --repo $REPO >/dev/null 2>&1
check_eq "release" "released" "$(status_of "$G" --release $A --vendor greptile --head $X --repo $REPO)"
check_eq "consume after release" "consumed" "$(status_of "$G" --consume $A --vendor greptile --head $X --repo $REPO)"
check_eq "release of an unused grant refused" "no_grant" "$(grant $A greptile $X >/dev/null; status_of "$G" --release $A --vendor greptile --head $X --repo $REPO)"

echo "== concurrent consumers: exactly one wins"
grant $A cursor $X >/dev/null
OUT="$TMP/race"; mkdir -p "$OUT"
for i in 1 2 3 4; do
  ( status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO > "$OUT/$i" ) &
done
wait
check_eq "one consumed" "1" "$(cat "$OUT"/* | grep -c '^consumed$')"
check_eq "the rest refused" "3" "$(cat "$OUT"/* | grep -cE '^(grant_lost_race|grant_used)$')"

echo "== on-demand offers: at or under the approved price only"
grant $A coderabbit $X 6.75 >/dev/null
check_eq "over the price refused" "offer_over_price" "$(status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 7.00 --currency USD --repo $REPO)"
check_eq "non-USD refused" "offer_currency_invalid" "$(status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 5 --currency EUR --repo $REPO)"
check_eq "non-numeric price refused" "offer_price_invalid" "$(status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 'up to' --currency USD --repo $REPO)"
check_eq "at the price accepted" "consumed" "$(status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 6.75 --currency usd --repo $REPO)"
check_eq "second offer refused" "grant_used" "$(status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 1 --currency USD --repo $REPO)"
check_eq "offer without any grant refused" "no_grant" "$(status_of "$G" --offer-check $B --vendor coderabbit --head $X --offer-price-usd 1 --currency USD --repo $REPO)"

echo "== --trigger: posts once under a grant, never without one"
rm -f "$POSTED"
grant $A cursor $X >/dev/null
check_eq "trigger A@X" "triggered" "$(status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "exactly one body posted" "1" "$(posts)"
check_eq "body is the BugBot trigger" "@cursor review" "$(cat "$POSTED")"
check_eq "second trigger A@X refused" "grant_used" "$(status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "trigger on PR B refused" "no_grant" "$(status_of "$G" --trigger $B --vendor cursor --head $X --repo $REPO)"
grant $A cursor $X >/dev/null
check_eq "live HEAD moved: refused" "grant_head_mismatch" "$(FIXTURE_HEAD=$Y status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "not your PR: refused" "not_author" "$(FIXTURE_AUTHOR_RC=1 status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "failed post" "trigger_failed" "$(FIXTURE_POST_FAIL=1 status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "failed post released the grant" "available" "$(status_of "$G" --check $A --vendor cursor --head $X --repo $REPO)"
check_eq "still only one body posted" "1" "$(posts)"
check_eq "trigger defaults --head to the live HEAD" "triggered" "$(status_of "$G" --trigger $A --vendor cursor --repo $REPO)"
grant $A greptile $X >/dev/null
check_eq "greptile budget exhausted: refused" "budget_exhausted" "$(FIXTURE_BUDGET_RC=1 status_of "$G" --trigger $A --vendor greptile --head $X --repo $REPO)"
check_eq "budget refusal released the grant" "available" "$(status_of "$G" --check $A --vendor greptile --head $X --repo $REPO)"
check_eq "greptile trigger" "triggered" "$(status_of "$G" --trigger $A --vendor greptile --head $X --repo $REPO)"
check_eq "greptile body" "@greptileai" "$(tail -1 "$POSTED")"
check_eq "coderabbit --trigger is a usage error" "2" "$(rc_of "$G" --trigger $A --vendor coderabbit --head $X --repo $REPO)"

echo "== the account daily cap (#1854) is asked before a grant is spent"
rm -f "$POSTED.cap"
grant $A cursor $X >/dev/null
BEFORE="$(posts)"
check_eq "cap over: trigger refused" "daily_cap_over" "$(FIXTURE_CAP_OVER=1 status_of "$G" --trigger $A --vendor cursor --head $X --repo $REPO)"
check_eq "cap over: nothing posted" "$BEFORE" "$(posts)"
check_eq "cap over: the grant stays unused" "available" "$(status_of "$G" --check $A --vendor cursor --head $X --repo $REPO)"
check_eq "cap asked for bugbot at its rate" "bugbot --add-usd 1.58" "$(tail -1 "$POSTED.cap")"
NOTE="$(FIXTURE_CAP_OVER=1 "$G" --trigger $A --vendor cursor --head $X --repo $REPO 2>&1 >/dev/null)"
check_eq "cap over: stderr tells the owner the cap" "1" "$(grep -c 'daily cap would be exceeded' <<<"$NOTE")"
grant $A coderabbit $X 6.75 >/dev/null
check_eq "cap over: offer refused" "daily_cap_over" "$(FIXTURE_CAP_OVER=1 status_of "$G" --offer-check $A --vendor coderabbit --head $X --offer-price-usd 5 --currency USD --repo $REPO)"
check_eq "offer asks the cap with the offer price" "coderabbit --add-usd 5" "$(tail -1 "$POSTED.cap")"

echo "== unreadable state fails closed with a visible note"
grant $A cursor $X >/dev/null
cp "$STATE" "$TMP/state.bak"
printf '{ not json' > "$STATE"
check_eq "corrupt file: consume refused" "grant_unreadable" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
check_eq "corrupt file: exit 3" "3" "$(rc_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
NOTE="$("$G" --trigger $A --vendor cursor --head $X --repo $REPO 2>&1 >/dev/null)"
check_eq "corrupt file: stderr names the refusal" "1" "$(grep -c 'no paid review' <<<"$NOTE")"
BEFORE="$(posts)"
"$G" --trigger $A --vendor cursor --head $X --repo $REPO >/dev/null 2>&1
check_eq "corrupt file: nothing posted" "$BEFORE" "$(posts)"
cp "$TMP/state.bak" "$STATE"
jq -c '.repos["acme/one"].prs["99701"].paid_review_grants.cursor = "yes"' "$TMP/state.bak" > "$STATE"
check_eq "string slot (a prose 'yes') is not a grant" "grant_unreadable" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
jq -c '.repos["acme/one"].prs["99701"].paid_review_grants.cursor.price_usd = "6"' "$TMP/state.bak" > "$STATE"
check_eq "malformed record refused" "grant_unreadable" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"
rm -f "$STATE"
check_eq "no state file: no grant" "no_grant" "$(status_of "$G" --consume $A --vendor cursor --head $X --repo $REPO)"

echo
echo "passed: $PASS, failed: $FAIL"
(( FAIL == 0 ))
