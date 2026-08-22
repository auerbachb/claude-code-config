#!/usr/bin/env bash
# review-substance.sh — Decide whether a bot's APPROVED review on a SHA
# represents an actual review, or is a hollow rubber stamp (issue #875).
#
# `merge-gate.sh` used to count ANY bot APPROVED whose commit_id matched HEAD as
# review coverage. Across the 2026-07-30/08-01 sessions those approvals were
# routinely empty-bodied and posted seconds after a push — sometimes with the
# bot's own status comment naming a DIFFERENT SHA, sometimes timestamped BEFORE
# that same bot announced it had started reviewing, and once directly after the
# bot said it had no review subscription. One PR merged on exactly that signal.
#
# Body length alone is NOT the test. A genuine CodeRabbit APPROVED was observed
# with bodylen=0 while its walkthrough comment named the exact reviewed range and
# listed every changed file. So the unit of evidence is the reviewer's WHOLE
# FOOTPRINT on that SHA, and the discriminators are ordered by decisiveness:
#
#   1. temporal_inversion    — the APPROVED predates the FIRST post-push
#                              "is running the review" marker from that same
#                              reviewer, AND that reviewer left no evidence
#                              outside the approval object that it read this
#                              commit. A review that had not started cannot have
#                              finished. Pure ordering violation.
#   2. capability_failure    — that reviewer said on this SHA that it could not
#                              review (no subscription / rate limited / couldn't
#                              run) and left no evidence outside the approval
#                              object that it read the commit anyway.
#   3. self_report_mismatch  — the reviewer's own latest SHA-naming comment names
#                              a commit other than the one it approved.
#   4. substantive           — review body OR inline comments on HEAD OR a
#                              same-SHA status comment naming HEAD OR a long
#                              descriptive comment in the current review round.
#                              Never body length on its own, and never a comment
#                              whose content is the reviewer declining to review
#                              or a fixed run-start/completion marker.
#   5. seconds_after_push    — reported only. Timing corroborates, never decides.
#
# This is a pure evaluator: no network, no gh calls. Callers pass the review and
# comment payloads they already fetched.
#
# Usage:
#   <json> | review-substance.sh [--min-chars N] [--reviewers a,b] [--corroborators a,b]
#   review-substance.sh --help
#
# Input (stdin, one JSON object):
#   {
#     "head_sha":        "abc123…",        # required
#     "push_ts":         "2026-07-31T…Z",  # optional; HEAD committer date
#     "reviews":         [ … ],            # pulls/{N}/reviews
#     "pr_comments":     [ … ],            # pulls/{N}/comments  (inline diff)
#     "issue_comments":  [ … ]             # issues/{N}/comments (conversation)
#   }
#
# Output (stdout, one JSON object):
#   {
#     "head_sha": "…", "min_chars": 40, "push_ts": "…",
#     "reviewers": { "<login>": {
#        "approved_on_head": true, "approval_submitted_at": "…",
#        "body_len": 0, "inline_comments_on_head": 0,
#        "status_comment_names_head": true,
#        "descriptive_evidence_on_head": true, "status_comment_shas": ["…"],
#        "self_report_mismatch": false,
#        "temporal_inversion": false, "run_start_marker_at": "…",
#        "capability_failure": false, "capability_failure_text": "",
#        "substantive": true, "counts_as_coverage": true,
#        "disqualified_by": [], "seconds_after_push": 214
#     } },
#     "substantive":       ["coderabbitai[bot]"],  # approvers that count as coverage
#     "hollow":            ["codeant-ai[bot]"],    # approved, but nothing read it
#     "mismatched":        [ … ],                  # approved X, self-reports Y
#     "inverted":          [ … ],                  # approved before its own run started
#     "capability_failed": [ … ],                  # said it could not review, approved anyway
#     "corroborating":     ["cursor[bot]"]         # substantive non-approvers on HEAD
#   }
#
# Signal details:
#
#   body_len                  length of the LATEST APPROVED review body on HEAD
#   inline_comments_on_head   inline diff comments anchored to HEAD (commit_id AND
#                             original_commit_id == HEAD, so comments GitHub
#                             "moved" forward on force-push do not count)
#   status_comment_names_head a conversation comment by that bot containing the
#                             HEAD SHA (full, or a >=7-char token that
#                             prefix-matches HEAD — hex OR all-decimal, issue
#                             #894) and >= min_chars long. No
#                             freshness filter is applied or needed: naming
#                             HEAD's SHA is itself proof the comment postdates it.
#                             Text the reviewer QUOTED rather than wrote is
#                             excluded before tokens are extracted — blockquote
#                             (">") lines, and lines reproduced verbatim from a
#                             non-reviewer comment on the same thread (issue
#                             #933). A bot that merely echoes the author's
#                             SHA-bearing re-review trigger no longer names HEAD.
#   descriptive_evidence_on_head
#                             a non-failure, non-marker conversation comment at
#                             least min_chars long, posted in the current HEAD
#                             round at or after that reviewer's earliest
#                             post-push run-start marker. It need not name HEAD:
#                             the marker and push bounds tie it to this round.
#                             This signal enters only $ext_substantive. It never
#                             enters $selfrep or $mismatch, so it can only grant
#                             coverage; it cannot manufacture a false mismatch
#                             or bypass an existing wrong-commit hard block.
#   self_report_mismatch      among that bot's conversation comments containing any
#                             SHA-like token, the MOST RECENT one names no SHA
#                             matching HEAD. SHA-like = \b[0-9a-f]{7,40}\b with at
#                             least one a-f letter, PLUS two all-decimal admissions
#                             (issue #894): a run that prefix-matches HEAD, and a
#                             run that is a complete inline code span. The code-span
#                             scan reads fence-stripped text (issue #897) so that
#                             a decimal run quoted inside a tilde fence, a
#                             four-space-indented block, or an unclosed backtick
#                             opener is not mistaken for a self-report. Bare digit
#                             runs in prose (dates, counts, IDs) still cannot
#                             manufacture a mismatch. Quoted/echoed text is
#                             excluded here too (issue #933): a SHA the reviewer
#                             only quoted is not the reviewer's self-report.
#                             See sha_tokens for why the code-span rule can only
#                             ever withhold coverage, and strip_echoed for the
#                             two directions the echo exclusion can move.
#   temporal_inversion        approval submitted_at < the EARLIEST post-push
#                             run-start marker from that reviewer. The earliest
#                             marker (not the latest) is deliberate: a re-review
#                             started AFTER a genuine approval would otherwise be
#                             read as an inversion. Requires push_ts; skipped
#                             (false) when push_ts is unknown, so a transient
#                             HEAD-timestamp API failure cannot invent a blocker.
#   capability_failure        a post-push comment from that reviewer matching a
#                             failure phrase, with NO substantive evidence from
#                             that reviewer timestamped after it. The trailing
#                             condition matters: CodeRabbit's rate-limit notice is
#                             temporary and is routinely followed by a real review
#                             (repo memory coderabbit-rate-limit-is-temporary), and
#                             that later evidence must win.
#   substantive               body_len >= min_chars OR inline_comments_on_head > 0
#                             OR status_comment_names_head OR
#                             descriptive_evidence_on_head
#   external_evidence_on_head substantive footprint OTHER than the approval body
#                             (inline comments, a status comment naming HEAD, a
#                             descriptive current-round comment, or a substantive
#                             non-APPROVED review); what suppresses a
#                             temporal_inversion verdict
#   counts_as_coverage        approved AND substantive AND none of the three
#                             disqualifiers above
#
# `corroborating` lists reviewers with a substantive footprint on HEAD that did
# not themselves approve (typically cursor[bot]). It is REPORTED, never gating:
# letting BugBot silently stand in for the CR-path requirement would be a
# different weakening of the gate, and keeping it advisory leaves issue #865's
# sticky-reviewer decision open.
#
# Freshness and retraction of the approval itself are NOT evaluated here — that
# stays in merge-gate.sh (issue #836). This script answers only "did anything
# actually read this commit".
#
# Exit codes:
#   0 — evaluated (JSON on stdout; says nothing about whether the gate passes)
#   2 — usage error
#   4 — bad/absent stdin JSON, or jq failure

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

MIN_CHARS="${MERGE_GATE_SUBSTANCE_MIN_CHARS:-40}"
REVIEWERS="coderabbitai[bot],codeant-ai[bot]"
CORROBORATORS="cursor[bot],greptile-apps[bot],graphite-app[bot]"

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --min-chars)
      MIN_CHARS="${2:-}"
      shift 2 ;;
    --reviewers)
      REVIEWERS="${2:-}"
      if [[ -z "$REVIEWERS" ]]; then
        echo "ERROR: --reviewers requires a comma-separated list" >&2
        exit 2
      fi
      shift 2 ;;
    --corroborators)
      CORROBORATORS="${2:-}"
      shift 2 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if ! [[ "$MIN_CHARS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: min-chars must be a non-negative integer (got: $MIN_CHARS)" >&2
  exit 2
fi

INPUT="$(cat)"
# Emptiness is tested with a plain -z, NOT `${INPUT// /}`: bash pattern
# substitution over a large string is O(n^2) on bash 3.2 (macOS default), and a
# real PR payload is ~1 MB — the whitespace-stripping form took minutes where
# this takes microseconds. A whitespace-only payload is caught by the jq -e
# validation immediately below, so nothing is lost.
if [[ -z "$INPUT" ]]; then
  echo "ERROR: no JSON on stdin" >&2
  exit 4
fi
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: stdin is not valid JSON" >&2
  exit 4
fi

OUT=$(printf '%s' "$INPUT" | jq -c \
  --argjson min_chars "$MIN_CHARS" \
  --arg reviewers "$REVIEWERS" \
  --arg corroborators "$CORROBORATORS" '

  # Everything is computed from ONE pre-normalised pass over each payload. jq
  # re-evaluates a `def` body at every call site, so helpers that re-scanned the
  # raw comment list per reviewer turned a millisecond job into ~1s per comment
  # on a real PR. The indexes below are built once and then only filtered.

  # Every ordering comparison below is a plain string compare, which is correct
  # only while all timestamps share one representation. GitHub REST returns
  # ISO-8601 UTC with a `Z` suffix, but `2026-08-01T07:26:30+00:00` sorts BEFORE
  # `2026-08-01T07:00:00Z` lexicographically, so a single non-`Z` spelling would
  # silently invert the marker / capability-failure / inversion ordering — the
  # same trap `norm_ts` guards against in merge-gate.sh. Fold the UTC spellings
  # onto `Z` and drop fractional seconds. A genuine non-UTC offset is left
  # untouched rather than mangled into a wrong instant.
  #
  # DELIBERATELY different from lib/ts-normalizer.sh (issue #885), which strips
  # the suffix and KEEPS the fraction.
  #
  # Precisely: merge-gate.sh does hand this script the SAME raw HEAD committer
  # date it uses as LAST_COMMIT_TS (arriving as `push_ts`), and that value is
  # compared against approval timestamps here. What never happens is a
  # comparison ACROSS the two rules — both sides of every compare below are
  # normalised by THIS function, so the ordering stays internally consistent.
  #
  # Dropping the fraction is more permissive than norm_ts (it can call equal
  # what the gate orders), and that is safe because the two verdicts are
  # independent and ANDed, not alternatives: merge-gate.sh evaluates
  # CR_APPROVAL_STALE / CA_APPROVAL_STALE with norm_ts and uses it as the OUTER
  # guard, with the counts_as_coverage verdict tested INSIDE it. Substance can
  # therefore only ever subtract coverage — it can never restore an approval
  # norm_ts has already ruled stale. Keep that nesting if either side is
  # refactored.
  #
  # Do not "unify" the two: tests/ts-normalizer-parity.test.sh pins both the
  # difference and that outer-guard ordering, so a refactor that erases either
  # fails loudly instead of silently reordering.
  def canon_ts:
    (. // "")
    | if . == "" then ""
      else sub("\\.[0-9]+"; "") | sub("(\\+00:00|\\+0000)$"; "Z")
      end;

  (.head_sha // "" | ascii_downcase)  as $sha
  | ((.push_ts // "") | canon_ts)     as $push
  | (.reviews // [])                  as $reviews
  | (.pr_comments // [])              as $inline
  | (.issue_comments // [])           as $convo
  | ($reviewers | split(",") | map(select(length > 0)))     as $approvers
  | ($corroborators | split(",") | map(select(length > 0))) as $others

  # ---- Echoed text: what a reviewer QUOTED is not what it SAID (issue #933) --
  #
  # Observed on PR #929: CodeAnt answers a re-review request by reproducing the
  # requester"s comment verbatim under a "Question:" heading and its own verdict
  # under "Answer:". The author"s trigger prose named HEAD"s short SHA, so the
  # bot"s body contained that SHA without the bot ever having written it, and
  # status_comment_names_head — the flag that says "this reviewer demonstrably
  # read HEAD" — went true on the strength of the AUTHOR"s words. Any ack or
  # summary reply that quotes the thread can do the same.
  #
  # THE RULE: drop a line of a reviewer"s comment when that exact line was
  # already posted on this thread by someone who is NOT one of the reviewers
  # under evaluation. Nothing else is dropped.
  #
  # Deliberately NOT "drop every blockquote line". That was the first cut, and
  # the live payload refuted it twice over. The PR #929 echo carries no ">" at
  # all, so a blockquote rule closes none of the reported trace; meanwhile the
  # ONLY ">" lines in that thread are CodeRabbit quoting ITSELF — its status
  # notice renders its own reviewed range as "> Reviewing files that changed …
  # between <base> and <head>". Blanket-stripping quotes would have silently
  # deleted a reviewer"s own self-report on every CodeRabbit status comment in
  # this repo. The issue asks to discount quoted/echoed AUTHOR text; a bot"s own
  # ">" callout is not author text. So quote markers are normalised away in the
  # lookup KEY instead (norm_line), which catches GitHub"s "Quote reply" shape —
  # "> " + the original line — while leaving self-quotation untouched.
  #
  # Only NON-reviewer comments seed the index, so a reviewer"s own lines are
  # never in it and a reviewer comment can never strip ITSELF to nothing. (A
  # non-reviewer"s comment does erase itself; its tokens are never read.)
  #
  # Ordered, not just matched: the index stores the EARLIEST time each line was
  # seen, and a line is only dropped from a comment created at or after that.
  # Echo means the source came first. Without the ordering, a human quoting a
  # bot"s line verbatim would retroactively strip the bot"s original.
  #
  # WHICH DIRECTIONS THIS CAN MOVE (the load-bearing argument, stated in full
  # because one of the two is a grant). Dropping a line, or truncating an echoed
  # fence line to its delimiter, can only ever REMOVE tokens, never add them:
  # split("\n") | join("\n") is the identity when nothing is dropped, an
  # untouched line is emitted byte-for-byte, and a truncated fence line keeps a
  # prefix of itself on its own line — no text is joined across a boundary, and
  # a run of ` or ~ carries no hex or decimal digit of its own. So the
  # indentation- and fence-sensitive rules below (issue #897) see exactly what
  # they always saw. From "tokens can only shrink":
  #
  #  - status_comment_names_head, external_evidence_on_head and substantive are
  #    monotone in the token set, so they can only move true -> false.
  #    Withholding a merge is recoverable (re-review and push). This is the
  #    grant path #933 closes.
  #  - self_report_mismatch can move BOTH ways. false -> true when a comment
  #    keeps a non-HEAD token but loses its HEAD one; true -> false when a
  #    comment"s ONLY tokens were quoted, so it stops being a self-report
  #    candidate at all. The second is a grant, and it is the SAME correction,
  #    not a side effect: a SHA the reviewer never wrote was never the
  #    reviewer"s report about itself, and reading it as one produces a blocker
  #    that no re-review can clear while the trigger prose stays quoted. Issue
  #    #917 accepted this identical direction for the identical reason (UUID
  #    fragments were manufacturing mismatches out of CodeRabbit"s own request
  #    ids). It is bounded: a comment carrying ANY SHA in the reviewer"s own
  #    prose keeps its tokens and its verdict.
  #  - counts_as_coverage therefore moves both ways too, and ONLY through that
  #    one channel (CodeRabbit CLI review of this PR — an earlier draft of this
  #    comment wrongly listed it as withhold-only). Every other input pushes it
  #    down: substantive can only fall, no_substantive_footprint can only
  #    appear, and temporal_inversion and capability_failure are both suppressed
  #    by $ext_substantive, which can only fall — so each can only newly fire.
  #    The single upward path is a cleared self_report_mismatch on a reviewer
  #    that is substantive on its own footprint, which is the corrected verdict,
  #    not a loosened one.
  | def norm_line:
      sub("^[ \t]*(>[ \t]*)+"; "") | sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "");

    ( reduce ( $convo[]?
               | ((.user.login // "")) as $l
               | select((($approvers + $others) | index($l)) == null)
               | ((((.created_at // .updated_at) // "") | canon_ts)) as $t
               | ((.body // "") | ascii_downcase | split("\n")[] | norm_line)
               | select(length > 0)
               | { k: ., t: $t } ) as $e
             ({}; if (.[$e.k] // null) == null or $e.t < .[$e.k]
                  then .[$e.k] = $e.t
                  else . end) ) as $echo_first

  # $ts is the created time of the comment being scanned. Input must already be
  # downcased — sha_tokens applies ascii_downcase first, and the index above is
  # downcased too, so matching is case-insensitive exactly like every other rule
  # here (CodeAnt"s PR #929 echo is a lowercased copy of the author"s line).
  # A source with no usable timestamp sorts first and so still strips: the
  # conservative direction, and GitHub always supplies one.
  #
  # FENCE DELIMITERS ARE NEVER DROPPED (CodeRabbit CLI review of this PR). A
  # bare "```" line is one of the most reproducible lines on a thread — every
  # comment carrying a code block has one — so it lands in the echo index almost
  # immediately, and dropping it would delete the delimiters of a REVIEWER"s own
  # fenced block. The #897 masking below is paired-delimiter matching: lose the
  # delimiters and quoted diff hunks are scanned as prose again, so numeric
  # literals in someone else"s source become self-report candidates. Losing only
  # the CLOSER is the worse half — the unclosed-opener rule then runs to
  # end-of-body and deletes rule-3 tokens that should have been admitted, which
  # is the grant direction. A delimiter carries no commit id of its own, so
  # keeping it costs nothing the echo rule was meant to buy. Pinned by
  # (ff-933)(j); only PAIRED syntax needs this, which is why four-space-indented
  # lines get no exception — dropping one removes its content too.
  #
  # THE DELIMITER, NOT THE LINE (CodeAnt PR #951 review). An exemption written
  # as "keep any line that STARTS with a fence marker" is wider than the
  # argument above, and the gap is on the grant side: "```5acd1e2" is a fence
  # opener whose info string is a SHA, so exempting the whole line readmits the
  # very token the echo rule just refused, and an empty-body approval scores
  # counts_as_coverage true on the author"s words again (reproduced on a live
  # payload before the fix). An echoed fence line is therefore truncated to its
  # own delimiter run — leading whitespace and quote markers preserved, info
  # string and any trailing text dropped. Paired matching sees an identical
  # delimiter either way (the masking regexes never read the info string), so
  # the structural reason for the exemption is untouched while its content
  # cannot smuggle evidence. Non-echoed fence lines are not rewritten at all.
  # Pinned by (ff-933)(k) and (ff-933)(l).
  | def strip_echoed($ts):
      [ ((. // "") | split("\n")[])
        | . as $ln
        | ($ln | norm_line) as $key
        | (($key | startswith("```")) or ($key | startswith("~~~"))) as $is_fence
        | ($echo_first[$key] // null) as $seen_at
        | (($seen_at != null) and ($seen_at <= $ts)) as $echoed
        | if ($echoed | not) then $ln
          elif $is_fence
          then ($ln | sub("^(?<w>[ \t]*)(?<q>(?:>[ \t]*)*)(?<f>`{3,}|~{3,}).*$";
                          "\(.w)\(.q)\(.f)"))
          else empty
          end ]
      | join("\n");

  # SHA-like tokens. THREE admission rules, deliberately asymmetric: each of the
  # two additions can move the verdict in exactly ONE direction, and which
  # direction is a structural property of the rule, not of the fixture that
  # happens to exercise it.
  #
  #  1. FORM (unchanged, issue #875). \b[0-9a-f]{7,40}\b containing at least one
  #     a-f letter. Form alone is enough here: prose does not emit hex-letter
  #     runs by accident, so no corroboration is required.
  #
  #  2. IDENTITY (issue #894). An ALL-DECIMAL \b[0-9]{7,40}\b run that
  #     prefix-matches the known HEAD SHA (or is prefixed by it) — precisely the
  #     comparison tokens_name_head is about to make anyway. Rule 1 alone
  #     discards a GENUINE short SHA that happens to be all decimal: 15 of the
  #     last 431 commits on this repo"s main (3.5%; (10/16)^7 in general). When
  #     HEAD is one of those, NO comment can name it, status_comment_names_head
  #     is structurally false, and the #876 stale-approval redemption can never
  #     fire — reinstating the exact wedge PR #893 was written to remove.
  #     Corroborating against HEAD"s IDENTITY rather than against token FORM is
  #     what makes this safe: a decimal run that is a genuine prefix of the
  #     actual HEAD SHA is not a coincidence worth guarding against (~1e-7), and
  #     it is the same exposure rule 1 has always carried for hex tokens.
  #
  #  3. CODE SPAN (issue #894). An ALL-DECIMAL run that is a COMPLETE inline
  #     code span (`1234567`) — the shape both bots use when naming the commit
  #     they reviewed ("## Review summary for `<sha>`"). This exists ONLY for
  #     the self_report_mismatch diagnostic: without it, a rubber stamp whose
  #     status comment names an OLDER all-decimal SHA yields no tokens at all,
  #     is therefore not a self-report candidate, and a long-bodied approval
  #     sails through with the contradiction unrecorded.
  #
  #     Rule 3 alone reads FENCE-STRIPPED text. A CodeRabbit walkthrough quotes
  #     diff hunks in ``` fences, and quoted code contains backticks of its own —
  #     a JS template literal `1234567` inside a fenced hunk is a numeric literal
  #     being DISCUSSED, not a commit the bot claims to have read (CodeRabbit CLI
  #     review of this PR). Rules 1-2 deliberately keep scanning the whole body:
  #     rule 1 must stay byte-identical to its pre-#894 behaviour, and rule 2 is
  #     anchored on HEAD"s identity, so a run that matches HEAD is HEAD wherever
  #     it appears. Only rule 3 infers commit-hood from surrounding punctuation,
  #     so only rule 3 needs the surrounding punctuation to be trustworthy.
  #
  # WHY RULE 3 CANNOT WEAKEN THE GATE (the load-bearing argument). Any token
  # admitted by rule 3 and not by rules 1-2 is, by construction, an all-decimal
  # run that does NOT prefix-match HEAD — otherwise rule 2 would already have
  # admitted it. So a rule-3-only token can never satisfy tokens_name_head:
  # names_head is byte-identical with and without rule 3. Its only reachable
  # effect is to ADD a self-report candidate that fails to name HEAD, i.e. to
  # move self_report_mismatch false -> true. It can never redeem a stale
  # approval, never clear a mismatch, never grant coverage. A false positive
  # here withholds a merge (recoverable — re-review and push); the direction it
  # structurally cannot take is the one that grants one.
  #
  # Bare decimal runs in prose ("reviewed 20260731 files across 1234567 lines")
  # remain unadmitted under all three rules — pinned by case (k).
  def sha_tokens($ts):
      ((. // "") | ascii_downcase | strip_echoed($ts)) as $btxt
      # Fence-stripped text for rule 3 only. Rules 1-2 keep reading $btxt (raw)
      # by design — "HEAD is HEAD wherever it appears", and rule 1 must stay
      # byte-identical to its pre-#894 behaviour. The flag is "m", NOT "s": jq
      # inverts the PCRE convention — jq"s "m" is what makes . match a newline,
      # and its "s" only rebinds ^ and $. With "s" these gsubs silently match
      # nothing and every fenced block is scanned as prose.
      #
      # Four shapes are stripped, in order:
      #   1. Closed ``` fences  — lazy quantifier stops at the FIRST closing
      #      fence so consecutive blocks are not swallowed with the prose between.
      #   2. Closed ~~~ fences  — same lazy discipline.
      #   3. Unclosed ``` opener → end-of-body — runs AFTER closed fences are
      #      removed, so it cannot swallow a later valid close. Two passes are
      #      needed: one for the start-of-body edge case (no preceding \n), then
      #      a gsub for every other line-starting opener. The pattern requires
      #      \n immediately before ``` so that inline triple-backticks inside
      #      prose (e.g. "use ``` for fencing") are NOT stripped.
      #   4. Four-space-indented lines — \n    [^\n]* matches each indented line
      #      (the leading newline is part of the match; the line-anchor flag "s"
      #      is not used because it does not do what PCRE multiline would do).
      | ($btxt
         | gsub("```.*?```"; " "; "m")
         | gsub("~~~.*?~~~"; " "; "m")
         | (if startswith("```") then sub("```.*"; " "; "m") else . end)
         | gsub("\n```.*"; " "; "m")
         | gsub("\n    [^\n]*"; " "; "m")
        ) as $unfenced
      # UUID-stripped text for rule 1 only (issue #917). CodeRabbit embeds an
      # invocation UUID in its HTML comments (8-4-4-4-12 hyphenated hex, e.g.
      # "9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6"). A hyphen is a non-word
      # character, so the UUID"s hex groups independently satisfy rule 1"s
      # shape (7-40 chars, at least one a-f letter) and get misread as SHAs
      # the bot claims to have reviewed. Each match is replaced with a space,
      # not stripped to empty, so a UUID sitting between two genuine tokens
      # cannot merge them into a new false one. Rules 2-3 are untouched: rule
      # 2 is safe regardless because it additionally requires a prefix match
      # against the real $sha, and rule 3 only admits complete
      # backtick-wrapped ALL-DECIMAL runs, which a hyphenated hex UUID never
      # satisfies.
      #
      # The boundary is a hex-lookaround, NOT \b (issue #917 follow-up,
      # CodeAnt PR #923 review): \b treats "_" as a word character equal to a
      # hex digit, so an identifier-glued UUID ("request_id_9f69125b-…") has
      # NO boundary before its first hex digit — the whole pattern fails to
      # match, the UUID is never stripped, and rule 1"s own scan still picks
      # up its trailing group ("8b5df9dcb5a6") as a bare hex token, exactly
      # reproducing the bug this fix exists to close. (?<![0-9a-f]) / (?![0-9a-f])
      # only refuse to START or END the match mid-hex-digit-run — they treat
      # "_" (or any other non-hex character) as a valid edge, so an
      # identifier-glued UUID is still recognized and stripped.
      | ($btxt | gsub("(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])"; " ")) as $unuuid
      | [ ( $unuuid | scan("\\b[0-9a-f]{7,40}\\b") | select(test("[a-f]")) ),
          ( $btxt | scan("\\b[0-9]{7,40}\\b") | . as $t
                  | select(($sha | length) > 0
                           and (($sha | startswith($t)) or ($t | startswith($sha)))) ),
          ( $unfenced | scan("`([0-9]{7,40})`") | .[0] ) ]
        | unique;

    # Does this token list identify $sha? A token matches when it prefixes the
    # full HEAD SHA (short form) or the full HEAD SHA prefixes it.
    def tokens_name_head:
      ($sha | length) > 0
      and any(.[]; . as $t | ($sha | startswith($t)) or ($t | startswith($sha)));

    # ---- Conversation index: one pass, all regex work done here -------------
    #
    # The echo scan is handed updated_at, NOT created_at (BugBot review of this
    # PR). GitHub freezes created_at when a comment is edited in place, and
    # editing in place is the norm here, not an edge case: CodeAnt PATCHes its
    # review body on re-review (#876) and CodeRabbit rewrites its walkthrough
    # comment. A bot that edits an echo of the author"s prose INTO a comment it
    # opened BEFORE the author wrote it would sort ahead of the index entry and
    # keep the line, manufacturing HEAD evidence — the grant direction, reached
    # without the bot ever writing the SHA.
    #
    # Both sides of the comparison are now biased the same way, toward
    # stripping: the index (above) keeps the EARLIEST time a source line can
    # have existed, and the scan takes the LATEST time the scanned body can have
    # been written. An in-place edit can therefore only ever withhold coverage,
    # never manufacture it. Unedited comments are unaffected — GitHub reports
    # updated_at == created_at — so the ordering guard pinned by (ff-933)(f) is
    # unchanged. Pinned by (ff-933)(n).
    ( [ $convo[]?
        | (.body // "") as $b
        | (((.updated_at // .created_at) // "") | canon_ts) as $cts
        # Measure only content-bearing reviewer-authored lines. strip_echoed
        # deliberately preserves blank separators and fence delimiters so SHA
        # masking keeps its structure; those remnants are not prose and must
        # not add up to the descriptive-evidence threshold on their own.
        | (($b | ascii_downcase | strip_echoed($cts))
           | [ split("\n")[]
               | norm_line
               | select(test("[^[:space:][:punct:]]")) ]
           | join("\n")
           | length) as $authored_len
        | (($b | sha_tokens($cts))) as $tok
        | { login:   (.user.login // ""),
            body:    $b,
            len:     ($b | length),
            authored_len: $authored_len,
            ts:      (((.updated_at // .created_at) // "") | canon_ts),
            created: (((.created_at // .updated_at) // "") | canon_ts),
            tokens:  $tok,
            names_head: ($tok | tokens_name_head),
            # "the review has started" markers, used for temporal inversion
            # "the review has started" markers. Deliberately NOT "review
            # triggered" (BugBot review, PR #883): that is the request being
            # ACCEPTED, not work beginning — pr-state.sh and poll-watermarks.sh
            # both classify "full review triggered" as an acknowledgment, and a
            # regression test pins it. Admitting it here contradicted that and
            # could mask a real inversion, because $marker takes the EARLIEST
            # post-push marker: a content-free ack landing first becomes the
            # marker, and an approval after it stops looking inverted against
            # the bot"s genuine "is running the review" notice later on.
            marker:  ($b | test("is running the review|is reviewing|review in progress|currently processing|started reviewing|started the review|is analyzing"; "i")),
            # Fixed completion notices prove only that a run ended. Match the
            # whole authored body so a real summary that happens to say
            # "review complete" in its prose remains eligible.
            completion_marker:
              ($b | test("^[[:space:][:punct:]]*((codeant ai|coderabbit|cursor bugbot|greptile)[[:space:]]+)?(finished running the review|(the )?review (is )?(now )?complete(d)?)[[:space:][:punct:]]*$"; "i")),
            # explicit "I cannot review this" notices
            failure: ($b | test("does not have a pr review subscription|no active subscription|not have an active subscription|rate limit|rate-limit|usage limit|usage or spend limit|quota exceeded|could not run|couldn'"'"'t run|unable to run|unable to review|unable to complete|failed to run|failed to review"; "i")) } ]
      | sort_by(.ts) ) as $cidx

    # ---- Inline diff comments anchored to HEAD ------------------------------
    # original_commit_id must also match: GitHub advances commit_id on comments
    # whose diff hunk survives a force-push, so commit_id alone would count
    # comments left on an earlier push.
    | ( [ $inline[]?
          | select(((.commit_id // "") | ascii_downcase) == $sha)
          | select((((.original_commit_id // .commit_id) // "") | ascii_downcase) == $sha)
          | { login: (.user.login // ""),
              ts: (((.updated_at // .created_at) // "") | canon_ts) } ] ) as $iidx

    # ---- Latest review per login on HEAD -----------------------------------
    | ( [ $reviews[]?
          | select(((.commit_id // "") | ascii_downcase) == $sha)
          | { login: (.user.login // ""),
              state: (.state // ""),
              body_len: ((.body // "") | length),
              submitted_at: ((.submitted_at // "") | canon_ts) } ] ) as $ridx

    | def secs_after_push($ts):
        if ($push == "" or ($ts // "") == "") then null
        else ((($ts | fromdateiso8601?) // null) as $a
              | (($push | fromdateiso8601?) // null) as $b
              | if ($a == null or $b == null) then null else ($a - $b) end)
        end;

    # ---- Per-approver evaluation -------------------------------------------
    ( [ $approvers[]
        | . as $login
        | ( [ $cidx[] | select(.login == $login) ] )                       as $mine

        # EARLIEST post-push run-start marker. Earliest, not latest: a re-review
        # kicked off AFTER a genuine approval would otherwise look inverted.
        #
        # ">=", not ">" — the push second is INCLUSIVE, matching fresh_review
        # below (BugBot review on c90b32a, PR #883). canon_ts has already
        # stripped fractional seconds, so a marker posted a fraction of a second
        # after the commit carries the SAME string as $push; under a strict ">"
        # it was discarded and temporal_inversion could not fire at all — which
        # is precisely when these bots post, seconds either side of the push.
        # One evaluator cannot read the push second as inclusive for reviews and
        # exclusive for markers. Including it is also the conservative direction:
        # inversion additionally requires the approval to be at or before the
        # marker, and $ext_substantive still clears any bot that really worked.
        | ( if $push == "" then null
            else ( [ $mine[] | select(.created >= $push and .marker) ]
                   | sort_by(.created) | first )
            end )                                                          as $marker

        | ( [ $ridx[] | select(.login == $login and .state == "APPROVED") ] )
                                                                           as $aps
        | ( $aps | sort_by(.submitted_at) | last )                         as $ap
        | ($ap.submitted_at // "")                                         as $ap_ts

        # Only reviews that POSTDATE the HEAD commit may contribute substance
        # (CodeAnt review, PR #883). GitHub retargets commit_id onto HEAD after a
        # force-push WITHOUT touching submitted_at, so an older substantive
        # review can surface here attached to a commit it never saw. merge-gate
        # freshness-checks the selected approval only, so pooling across every
        # commit_id match would let a stale body vouch for a fresh empty
        # duplicate. Mirrors the #836 stale-approval rule. When $push is
        # unavailable the filter opens up rather than guessing — merge-gate fails
        # closed on unverifiable freshness separately.
        | def fresh_review: select($push == "" or (.submitted_at >= $push));

          ( [ $aps[] | fresh_review | .body_len ] | max // 0 )             as $body_len

        # Substance is not APPROVED-only (BugBot review, PR #883). A bot that
        # leaves a long COMMENTED review on this SHA and then an empty APPROVED
        # has demonstrably read the commit — that is BugBot"s normal shape, and
        # CodeAnt"s genuine pass on a1c03ed was a COMMENTED review too. Tracked
        # separately from $body_len so the reported figure still describes the
        # approval itself.
        | ( [ $ridx[]
              | select(.login == $login and .state != "APPROVED")
              | fresh_review | .body_len ] | max // 0 )                    as $other_review_len

        | ( [ $iidx[] | select(.login == $login) ] )                       as $inl
        # A status comment only evidences a review if it is not the reviewer
        # ANNOUNCING IT COULD NOT REVIEW. Capability-failure notices routinely
        # name HEAD and run well past $min_chars — CodeRabbit"s rate-limit notice
        # quotes the exact commit range it declined to review — so without this
        # filter the notice would make itself substantive AND, by landing in $ev
        # below, suppress the capability_failure check that exists to catch it.
        # Priority order is documented failure-before-substance; this enforces it.
        | ( [ $mine[]
              | select(.len >= $min_chars and .names_head and (.failure | not)) ] ) as $status_ev
        | (($status_ev | length) > 0)                                      as $names_head

        # A run-start or fixed completion marker cannot serve as its own
        # evidence, even when it clears a configured length threshold: it says
        # only that work began or ended, not that any diff was read. The length
        # threshold also uses authored_len, after the existing
        # echoed-author-line filter; borrowed prose cannot become the bot"s
        # evidence merely by being quoted.
        # A separate long descriptive comment posted at or after the marker is
        # evidence that the bot read the current diff even when it does not repeat
        # HEAD"s SHA. This admission channel is intentionally one-directional: it
        # feeds only external substance and never $selfrep or $mismatch. An
        # existing wrong-SHA self-report therefore remains a hard disqualifier
        # even when this value is true.
        | ( $marker != null and
            ([ $mine[]
               | select(.authored_len >= $min_chars
                        and (.failure | not)
                        and (.marker | not)
                        and (.completion_marker | not)
                        and .created >= $push
                        and .created >= $marker.created) ]
             | length) > 0 )                                               as $descriptive_ev
        # Substance that exists INDEPENDENTLY of the approval object itself:
        # inline comments anchored to HEAD, a status comment naming HEAD, a
        # descriptive current-round comment, or a substantive non-APPROVED
        # review on HEAD. The approval"s own body is excluded on purpose — see
        # $inversion below.
        | ( (($inl | length) > 0) or $names_head
            or $descriptive_ev
            or ($other_review_len >= $min_chars) )                         as $ext_substantive

        | ( ($body_len >= $min_chars) or $ext_substantive )                as $substantive

        # Self-report mismatch: of this bot"s comments that mention ANY commit
        # id, the most recent one mentions none matching HEAD. Restricting to
        # SHA-naming comments keeps content-free acks ("Full review triggered")
        # from masking the walkthrough that carries the self-report.
        # Ordered by .created, NOT by $cidx order: $cidx sorts on .ts, which is
        # updated_at, and these bots edit comments in place — CodeRabbit rewrites
        # its rate-limit notice to name each new commit range as the PR moves. So
        # an older comment naming HEAD, edited later for unrelated reasons, could
        # sort last and mask the bot"s genuinely newest SHA-naming post (BugBot
        # review, PR #883). Post time is the stable, monotonic dimension.
        | ( [ $mine[] | select((.tokens | length) > 0) ]
            | sort_by(.created) | last )                                   as $selfrep
        | ( $selfrep != null and ($selfrep.names_head | not) )             as $mismatch

        # Capability failure: a post-push notice that this reviewer could not
        # review, and no evidence outside the approval object that it read the
        # commit anyway. $ext_substantive is the same term $inversion uses, for
        # the same two reasons:
        #
        #  - The approval"s own body must not clear the failure. It used to: the
        #    body"s timestamp counted as post-failure evidence, so a long generic
        #    APPROVED posted right after a "cannot review" notice cleared
        #    capability_failure and took counts_as_coverage with it — the
        #    mia#172 476798e trace with a non-empty body.
        #  - Genuine external work redeems the approval whenever it lands, before
        #    OR after the notice. CodeRabbit"s rate limit is temporary and is
        #    routinely followed by a real review (repo memory
        #    coderabbit-rate-limit-is-temporary); it is equally often a limit hit
        #    on a LATER re-review request, which must not retroactively void the
        #    walkthrough that already named this SHA.
        # ">=" for the same reason as $marker above: the push second is
        # inclusive, so a "cannot review" notice landing in the same second as
        # the commit is still a post-push notice (BugBot review on c90b32a).
        | ( if $push == "" or $ext_substantive then null
            else ( [ $mine[] | select(.created >= $push and .failure) ]
                   | sort_by(.created) | last )
            end )                                                          as $fail

        # Temporal inversion: the approval predates this reviewer"s own
        # "I have started reviewing" marker, and the reviewer left NO evidence
        # outside the approval object that it ever read this commit.
        #
        # The suppressing term is $ext_substantive, deliberately, and it is not
        # time-bounded. Two failure modes are being avoided at once:
        #
        #  - Keying off the approval"s own body is circular. The body is the
        #    thing under suspicion, so a verbose rubber stamp posted before its
        #    own start marker would exonerate itself and inversion would never
        #    fire on it.
        #  - Requiring the external evidence to PREDATE the approval would break
        #    the documented genuine shape: CodeRabbit"s `bodylen=0` APPROVED whose
        #    walkthrough lands moments later (mia#172 `396ced5`). Evidence that
        #    the reviewer really did read this SHA redeems the approval whenever
        #    it arrives.
        #
        # $fail above resolves to the same rule from the other direction, so
        # signals 1 and 2 now share one invariant: an approval"s own body never
        # vouches for itself, and external evidence redeems it whenever it lands.
        #
        # What survives both: an approval with no inline comments and no status
        # comment naming HEAD, posted before that bot said it had started. That
        # is the ccc#867 shape — approved 06:24:44Z, marker 06:24:50Z, nothing
        # else — and it stays disqualified.
        #
        # `<=`, not `<`: GitHub emits these timestamps at whole-second
        # granularity, so an approval and that bot"s own start marker landing in
        # the SAME second cannot be ordered from the data — and no real review
        # begins and finishes inside one second, so the same-second case belongs
        # with the inversions rather than with the clean approvals (BugBot
        # review, PR #883). Restoring sub-second precision is not the
        # alternative: mixed precision breaks the lexicographic compare outright,
        # because "10:00:22.5Z" sorts BEFORE "10:00:22Z" ("." < "Z"), which is
        # why canon_ts strips fractional seconds in the first place.
        # $ext_substantive still guards the innocent shape — a bot that really
        # reviewed leaves evidence outside the approval and is never flagged.
        #
        # The pooled $body_len deliberately does NOT feed this term, so a
        # reviewer can be `substantive` and `temporal_inversion` at once (BugBot
        # review, PR #883, declined; pinned by case (bb)). That asymmetry IS the
        # rule: $substantive asks whether content exists, inversion asks whether
        # it existed before the work did. Letting a pooled approval body clear
        # inversion restores the circular form CodeAnt raised as a Critical
        # earlier on this PR — a verbose stamp posted before its own start
        # marker exonerating itself.
        | ( $ap != null and $marker != null and $ap_ts != ""
            and ($ap_ts <= $marker.created)
            and ($ext_substantive | not) )                                 as $inversion
        | ( $ap != null and $fail != null )                                as $cap_fail

        | ( [ (if ($ap != null and ($substantive | not)) then "no_substantive_footprint" else empty end),
              (if ($ap != null and $mismatch) then "self_report_mismatch" else empty end),
              (if $inversion then "temporal_inversion" else empty end),
              (if $cap_fail then "capability_failure" else empty end) ] )  as $disq

        | { key: $login,
            value: {
              approved_on_head:          ($ap != null),
              approval_submitted_at:     $ap_ts,
              body_len:                  $body_len,
              inline_comments_on_head:   ($inl | length),
              status_comment_names_head: $names_head,
              descriptive_evidence_on_head: $descriptive_ev,
              other_review_body_len:     $other_review_len,
              external_evidence_on_head: $ext_substantive,
              status_comment_shas:       (($selfrep.tokens // []) | unique),
              self_report_mismatch:      ($ap != null and $mismatch),
              temporal_inversion:        $inversion,
              run_start_marker_at:       (($marker.created) // ""),
              capability_failure:        $cap_fail,
              # The only field here that carries a bot comment body verbatim.
              # Control characters are folded to spaces so no consumer ever has
              # to survive an escape sequence in this payload (issue #1219). The
              # substitution is 1:1, so truncating first gives the identical
              # 160-char result while never scanning a large body.
              capability_failure_text:   (($fail.body // "") | .[0:160] | gsub("[[:cntrl:]]"; " ")),
              substantive:               $substantive,
              counts_as_coverage:        ($ap != null and $substantive and ($disq | length) == 0),
              disqualified_by:           $disq,
              seconds_after_push:        secs_after_push($ap_ts)
            } } ]
      | from_entries ) as $map

    # ---- Corroborators — substantive footprint on HEAD without approving ----
    # Advisory only: letting BugBot silently stand in for the CR-path
    # requirement would be a different weakening of the gate, and keeping this
    # non-gating leaves the sticky-reviewer decision in issue #865 open.
    | ( [ $others[]
          | . as $login
          | select(
              ( [ $ridx[] | select(.login == $login) ]
                | sort_by(.submitted_at) | last | (.body_len // 0) ) >= $min_chars
              or ( [ $iidx[] | select(.login == $login) ] | length ) > 0
              or ( [ $cidx[] | select(.login == $login and .len >= $min_chars and .names_head and (.failure | not)) ] | length ) > 0
            ) ] ) as $corroborating

    | {
        head_sha: $sha,
        push_ts: $push,
        min_chars: $min_chars,
        reviewers: $map,
        substantive:       [ $map | to_entries[] | select(.value.counts_as_coverage) | .key ],
        hollow:            [ $map | to_entries[] | select(.value.approved_on_head and (.value.counts_as_coverage | not)) | .key ],
        mismatched:        [ $map | to_entries[] | select(.value.approved_on_head and .value.self_report_mismatch) | .key ],
        inverted:          [ $map | to_entries[] | select(.value.temporal_inversion) | .key ],
        capability_failed: [ $map | to_entries[] | select(.value.capability_failure) | .key ],
        corroborating:     $corroborating
      }
') || {
  echo "ERROR: jq evaluation failed" >&2
  exit 4
}

if [[ -z "$OUT" ]] || ! printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: evaluator produced no JSON" >&2
  exit 4
fi

printf '%s\n' "$OUT"
