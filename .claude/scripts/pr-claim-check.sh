#!/usr/bin/env bash
# pr-claim-check.sh — Compare a PR's claim-holder line with each linked issue's winning claim (issue #2288).
# catalog: merge-gate-sequencing — PR-side claim gate: flags a PR opened on an issue another agent holds, or a PR that names no claim (CI runs it via pr-claim-check.yml)
#
# PURPOSE
#   Every pull request passes through GitHub, whichever agent wrote it. This
#   script answers one question for a PR: does the holder it names match the
#   holder of each issue it closes? It prints ONE JSON object and exits 0 for
#   every verdict. Only a usage error exits 2.
#
# VERDICTS (worst per-issue outcome wins, in this order)
#   foreign > unverifiable > no_claim_line > match > pass_unclaimed > skipped
#
#   Per-issue outcome (from the real issue-claim.sh --check --json):
#     unclaimed | stale         -> pass_unclaimed
#     claimed, holder digest == the PR's claim-holder line -> match
#     claimed, PR has no claim-holder line                 -> no_claim_line
#     claimed, digests differ                              -> foreign
#     unknown, not_found, closed issue, unreadable claim or PR line -> unverifiable
#   Overall skipped: bot author (bot_author), or no closing keyword (no_linked_issue).
#
# NEVER PRINTS THE RAW HOLDER
#   A foreign result names the holder's provider, device and label only. The
#   raw holder token can carry a hostname and a path, so it never leaves this
#   script, not even on stderr.
#
# --report MODE (used by pr-claim-check.yml)
#   Also maps the verdict to CI: match, pass_unclaimed and skipped pass
#   silently; no_claim_line and unverifiable pass with a ::warning::; foreign
#   fails (exit 1) with a ::error::. no_claim_line, unverifiable and foreign
#   post one PR comment, and only when a comment with the same hidden marker
#   (<!-- pr-claim-check:<verdict>:<issues> -->) is not already on the PR.
#
# USAGE
#   pr-claim-check.sh <PR> [--repo OWNER/NAME] [--report]
#   pr-claim-check.sh --help | -h
#
# DEPENDENCIES
#   gh (authenticated), jq, issue-claim.sh (same directory), and shasum or
#   sha256sum. Reads only; --report also writes one PR comment per new outcome.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_CLAIM="$SCRIPT_DIR/issue-claim.sh"

usage() {
  cat <<'USAGE'
Usage: pr-claim-check.sh <PR> [--repo OWNER/NAME] [--report]
       pr-claim-check.sh --help | -h

Prints one JSON object describing the PR's claim verdict. Exit 0 for every
verdict; exit 2 for a usage error.

--repo OWNER/NAME  Act on this repository (default: the current checkout).
--report           CI mode: map the verdict to annotations, a step summary,
                   one deduplicated PR comment, and an exit status (foreign
                   exits 1, every other verdict exits 0).
USAGE
}

usage_err() {
  echo "pr-claim-check.sh: $1" >&2
  usage >&2
  exit 2
}

PR=""
REPO=""
REPORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [[ $# -ge 2 ]] || usage_err "--repo needs a value"
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --report) REPORT=1; shift ;;
    -*) usage_err "unknown flag: $1" ;;
    *)
      [[ -z "$PR" ]] || usage_err "unexpected extra argument: $1"
      PR="$1"; shift ;;
  esac
done

[[ -n "$PR" ]] || usage_err "missing PR number"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage_err "PR number must be a positive integer"
if [[ -n "$REPO" ]]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_err "--repo must be OWNER/NAME"
fi

TMPD="$(mktemp -d 2>/dev/null)" || { echo '{"verdict":"unverifiable","reason":"tempdir_unavailable","claim_line":false,"issues":[]}'; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

# digest_hex <text> <n>: first n hex chars of a SHA-256. Fails closed.
digest_hex() {
  local d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64)"
  elif command -v sha256sum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64)"
  fi
  [[ -n "$d" ]] || return 1
  printf '%s' "${d:0:$2}"
}

# canonical_holder <raw>: the claim-holder value for a raw holder (see pr-claim-line.sh).
canonical_holder() {
  if [[ "$1" =~ ^h-[0-9a-f]{12}$ ]]; then
    printf '%s' "$1"
    return 0
  fi
  local d
  d="$(digest_hex "$1" 12)" || return 1
  printf 'h-%s' "$d"
}

# rank <verdict>: higher is worse. Used to pick the overall verdict.
rank() {
  case "$1" in
    foreign) echo 5 ;;
    unverifiable) echo 4 ;;
    no_claim_line) echo 3 ;;
    match) echo 2 ;;
    pass_unclaimed) echo 1 ;;
    *) echo 0 ;;
  esac
}

# finish <verdict> <reason> <claim_line true|false> <issues-json-array> : print the result object.
RESULT_REPO="${REPO:-unknown}"
finish() {
  OVERALL="$1"; OVERALL_REASON="$2"
  jq -cn \
    --argjson pr "$PR" \
    --arg repo "$RESULT_REPO" \
    --arg verdict "$1" \
    --arg reason "$2" \
    --argjson claim_line "$3" \
    --argjson issues "$4" \
    '{pr: $pr, repo: $repo, verdict: $verdict, reason: $reason, claim_line: $claim_line, issues: $issues}'
  # Every exit path (including unverifiable early exits) goes through the CI
  # mapping, so a failed read warns in --report mode instead of passing silently.
  if [[ "$REPORT" -eq 1 ]]; then
    report_outcome
  fi
  exit 0
}

# Issue objects accumulate here as JSON texts, joined into an array at the end.
ISSUE_OBJS=()
issues_json() {
  if [[ "${#ISSUE_OBJS[@]}" -eq 0 ]]; then
    printf '[]'
  else
    local IFS=','
    printf '[%s]' "${ISSUE_OBJS[*]}"
  fi
}

# add_issue <issue> <outcome> <reason> [provider device label]
add_issue() {
  local obj
  obj="$(jq -cn --argjson n "$1" --arg o "$2" --arg r "$3" \
    --arg p "${4:-}" --arg d "${5:-}" --arg l "${6:-}" \
    '{issue: $n, outcome: $o, reason: $r}
     + (if $o == "foreign" then {provider: (if $p == "" then null else $p end),
                                  device: (if $d == "" then null else $d end),
                                  label: (if $l == "" then null else $l end)} else {} end)')"
  ISSUE_OBJS+=("$obj")
}

main() {
# ---- 1. Resolve the repository ------------------------------------------------
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // ""' 2>/dev/null)" || REPO=""
  RESULT_REPO="${REPO:-unknown}"
  if [[ -z "$REPO" ]]; then
    finish unverifiable repo_unresolved false '[]'
    exit 0
  fi
fi
RESULT_REPO="$REPO"

# ---- 2. Read the PR -----------------------------------------------------------
if ! gh api "repos/$REPO/pulls/$PR" >"$TMPD/pr.json" 2>"$TMPD/err"; then
  finish unverifiable pr_read_failed false '[]'
  exit 0
fi
AUTHOR="$(jq -r '.user.login // ""' "$TMPD/pr.json" 2>/dev/null)" || AUTHOR=""
AUTHOR_TYPE="$(jq -r '.user.type // ""' "$TMPD/pr.json" 2>/dev/null)" || AUTHOR_TYPE=""
if [[ -z "$AUTHOR" ]] || ! jq -e '.body == null or (.body | type == "string")' "$TMPD/pr.json" >/dev/null 2>&1; then
  finish unverifiable pr_read_failed false '[]'
  exit 0
fi
case "$AUTHOR" in
  *'[bot]') AUTHOR_TYPE="Bot" ;;
esac
if [[ "$AUTHOR_TYPE" == "Bot" ]]; then
  finish skipped bot_author false '[]'
  exit 0
fi

jq -r '.body // ""' "$TMPD/pr.json" >"$TMPD/body.md"

# strip_body <keep_comments 0|1> <infile> <outfile>: drop fenced code blocks
# (and, when keep_comments is 0, HTML comments) so neither can carry a keyword
# or a claim line the author did not mean.
strip_body() {
  awk -v keep="$1" '
    # A fence opens with 3+ backticks or tildes and closes only with the same
    # character, at least as long, and nothing else on the line.
    BEGIN { fence = 0; fch = ""; flen = 0; com = 0 }
    {
      t = $0; sub(/^[[:space:]]*/, "", t)
      ch = substr(t, 1, 1)
      n = 0
      if (ch == "`" || ch == "~") { while (substr(t, n + 1, 1) == ch) n++ }
      if (fence) {
        if (n >= flen && ch == fch && substr(t, n + 1) ~ /^[[:space:]]*$/) fence = 0
        next
      }
      if (n >= 3) { fence = 1; fch = ch; flen = n; next }
    }
    fence { next }
    {
      line = $0
      if (keep == "1") { print line; next }
      out = ""
      while (length(line) > 0) {
        if (com) {
          p = index(line, "-->")
          if (p == 0) { line = "" } else { line = substr(line, p + 3); com = 0 }
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); com = 1 }
        }
      }
      print out
    }' "$2" >"$3"
}

# ---- 3. Read the PR's claim-holder line ---------------------------------------
strip_body 1 "$TMPD/body.md" "$TMPD/body_fenced_only.md"
CLAIM_LINES="$(LC_ALL=C grep -F '<!-- claim-holder:' "$TMPD/body_fenced_only.md" 2>/dev/null || true)"
CLAIM_LINE_PRESENT=false
PR_HOLDER=""
MALFORMED=0
if [[ -n "$CLAIM_LINES" ]]; then
  CLAIM_LINE_PRESENT=true
  FIRST_LINE="$(printf '%s\n' "$CLAIM_LINES" | head -n 1)"
  if LC_ALL=C grep -qE '^[[:space:]]*<!-- claim-holder: h-[0-9a-f]{12} -->[[:space:]]*$' <<<"$FIRST_LINE"; then
    PR_HOLDER="$(printf '%s' "$FIRST_LINE" | LC_ALL=C grep -oE 'h-[0-9a-f]{12}')"
  else
    MALFORMED=1
  fi
fi

# ---- 4. Linked issues from closing keywords -----------------------------------
strip_body 0 "$TMPD/body.md" "$TMPD/body_text.md"
KEYWORD_RE='(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+'
REFS="$(LC_ALL=C grep -oiE "$KEYWORD_RE" "$TMPD/body_text.md" 2>/dev/null)" || REFS=""
REPO_LC="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
NUMS=""
while IFS= read -r REF; do
  [[ -n "$REF" ]] || continue
  # The reference is the last space- or colon-separated token: #N or owner/name#N.
  # The match ends in [owner/name]#N; whatever keyword or separator precedes it is ignored.
  [[ "$REF" =~ ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)$ ]] || continue
  QUAL="${BASH_REMATCH[1]}"
  QUAL_LC="$(printf '%s' "$QUAL" | tr '[:upper:]' '[:lower:]')"
  # A reference qualified to another repository names an issue this check cannot read.
  if [[ -n "$QUAL" && "$QUAL_LC" != "$REPO_LC" ]]; then continue; fi
  NUMS="$NUMS${BASH_REMATCH[2]}
"
done <<<"$REFS"
LINKED="$(printf '%s' "$NUMS" | LC_ALL=C grep -E '^[0-9]+$' | LC_ALL=C sort -n -u)" || LINKED=""

if [[ -z "$LINKED" ]]; then
  finish skipped no_linked_issue "$CLAIM_LINE_PRESENT" '[]'
  exit 0
fi

# ---- 5. Compare each linked issue ---------------------------------------------
for N in $LINKED; do
  # The issue must exist and be open; anything else cannot be verified.
  if ! gh api "repos/$REPO/issues/$N" >"$TMPD/issue.json" 2>/dev/null; then
    add_issue "$N" unverifiable issue_read_failed
    continue
  fi
  ISSUE_STATE="$(jq -r '.state // ""' "$TMPD/issue.json" 2>/dev/null)" || ISSUE_STATE=""
  if [[ "$ISSUE_STATE" != "open" ]]; then
    add_issue "$N" unverifiable issue_not_open
    continue
  fi
  if [[ "$MALFORMED" -eq 1 ]]; then
    add_issue "$N" unverifiable pr_claim_line_malformed
    continue
  fi
  if [[ ! -f "$ISSUE_CLAIM" ]]; then
    add_issue "$N" unverifiable claim_helper_missing
    continue
  fi

  CLAIM_OUT="$(bash "$ISSUE_CLAIM" "$N" --check --json --repo "$REPO" --holder pr-claim-check 2>/dev/null)" || true
  VERDICT="$(printf '%s' "$CLAIM_OUT" | jq -r '.verdict // ""' 2>/dev/null)" || VERDICT=""
  case "$VERDICT" in
    unclaimed|stale)
      add_issue "$N" pass_unclaimed "$VERDICT" ;;
    claimed)
      RAW_HOLDER="$(printf '%s' "$CLAIM_OUT" | jq -r '.claimant_holder // ""' 2>/dev/null)" || RAW_HOLDER=""
      if [[ -z "$RAW_HOLDER" ]]; then
        add_issue "$N" unverifiable claim_holder_unreadable
        continue
      fi
      WANT="$(canonical_holder "$RAW_HOLDER")" || { add_issue "$N" unverifiable digest_unavailable; continue; }
      if [[ "$CLAIM_LINE_PRESENT" != "true" ]]; then
        add_issue "$N" no_claim_line claimed_pr_has_no_claim_line
      elif [[ "$WANT" == "$PR_HOLDER" ]]; then
        add_issue "$N" match holder_matches
      else
        P="$(printf '%s' "$CLAIM_OUT" | jq -r '.provider // ""' 2>/dev/null)" || P=""
        D="$(printf '%s' "$CLAIM_OUT" | jq -r '.device // ""' 2>/dev/null)" || D=""
        L="$(printf '%s' "$CLAIM_OUT" | jq -r '.label // ""' 2>/dev/null)" || L=""
        add_issue "$N" foreign other_holder "$P" "$D" "$L"
      fi ;;
    *)
      add_issue "$N" unverifiable "claim_state_${VERDICT:-unreadable}" ;;
  esac
done

# ---- 6. Overall verdict -------------------------------------------------------
OVERALL="skipped"
OVERALL_REASON="no_decision"
for OBJ in ${ISSUE_OBJS[@]+"${ISSUE_OBJS[@]}"}; do
  O="$(printf '%s' "$OBJ" | jq -r '.outcome')"
  if [[ "$(rank "$O")" -gt "$(rank "$OVERALL")" ]]; then
    OVERALL="$O"
    OVERALL_REASON="$(printf '%s' "$OBJ" | jq -r '.reason')"
  fi
done
[[ "${#ISSUE_OBJS[@]}" -gt 0 ]] || { OVERALL="skipped"; OVERALL_REASON="no_linked_issue"; }

finish "$OVERALL" "$OVERALL_REASON" "$CLAIM_LINE_PRESENT" "$(issues_json)"

}

# ---- 7. --report: CI mapping, deduplicated comment ----------------------------
# Called only from finish(), so it always sees the final OVERALL and issue list.
report_outcome() {
  if [[ "$OVERALL" == "skipped" || "$OVERALL" == "match" || "$OVERALL" == "pass_unclaimed" ]]; then
    LINE="pr-claim-check: $OVERALL on PR #$PR"
    echo "$LINE"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$LINE" >>"$GITHUB_STEP_SUMMARY"; fi
    exit 0
  fi

  # The marker lists the issues that drove the verdict, so a changed set posts anew.
  ISSUE_LIST="$(printf '%s\n' "$LINKED" | LC_ALL=C sort -n -u | paste -sd, -)"
  MARKER="<!-- pr-claim-check:$OVERALL:$ISSUE_LIST -->"

  case "$OVERALL" in
    foreign)
      SEV="error"
      BODY_TEXT="**Claim check failed.** This PR closes an issue that another agent holds."
      for OBJ in ${ISSUE_OBJS[@]+"${ISSUE_OBJS[@]}"}; do
        O="$(printf '%s' "$OBJ" | jq -r '.outcome')"
        [[ "$O" == "foreign" ]] || continue
        N="$(printf '%s' "$OBJ" | jq -r '.issue')"
        P="$(printf '%s' "$OBJ" | jq -r '.provider // "unknown"')"
        D="$(printf '%s' "$OBJ" | jq -r '.device // "unknown"')"
        L="$(printf '%s' "$OBJ" | jq -r '.label // "none"')"
        BODY_TEXT="$BODY_TEXT
- Issue #$N is claimed by provider \`$P\` on device \`$D\` (label: \`$L\`)."
      done
      BODY_TEXT="$BODY_TEXT

Stop this work, or if that claim is stale, take it over first with \`issue-claim.sh <N> --claim\`, then update this PR body's \`claim-holder\` line to match." ;;
    no_claim_line)
      SEV="warning"
      BODY_TEXT="**Claim check: no claim line.** This PR closes a claimed issue but its body has no \`claim-holder\` line. Add the line that \`.claude/scripts/pr-claim-line.sh <ISSUE>\` prints. This is a warning, not a failure." ;;
    unverifiable)
      SEV="warning"
      BODY_TEXT="**Claim check: could not verify ownership.** The issue claim or this PR's claim line could not be read, so this check passes with a warning, not as a match. Confirm the claim by hand, or re-run the check once the cause clears." ;;
  esac

  echo "::$SEV::pr-claim-check $OVERALL on PR #$PR (issues: $ISSUE_LIST): $OVERALL_REASON"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'pr-claim-check: %s on PR #%s\n' "$OVERALL" "$PR" >>"$GITHUB_STEP_SUMMARY"
  fi

  # Dedupe: one comment per PR per outcome and issue set.
  if ! gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" >"$TMPD/comments.json" 2>/dev/null; then
    echo "pr-claim-check: could not list PR comments; not posting" >&2
  else
    EXISTING="$(jq -s --arg m "$MARKER" '[ (add // [])[] | select(((.body // "") | startswith($m))) ] | length' "$TMPD/comments.json" 2>/dev/null)" || EXISTING=""
    if [[ "$EXISTING" == "0" ]]; then
      FULL_BODY="$MARKER
$BODY_TEXT"
      if ! gh api -X POST "repos/$REPO/issues/$PR/comments" -f body="$FULL_BODY" >/dev/null 2>"$TMPD/post.err"; then
        echo "pr-claim-check: could not post the PR comment" >&2
      fi
    elif [[ -n "$EXISTING" ]]; then
      echo "pr-claim-check: comment for this outcome already on the PR; not posting again" >&2
    fi
  fi

  [[ "$OVERALL" == "foreign" ]] && exit 1
  exit 0
}

main "$@"
