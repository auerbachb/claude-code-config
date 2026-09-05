#!/usr/bin/env bash
# review-substance.sh — Decide whether a bot's APPROVED review on a SHA
# represents an actual review, or is a hollow rubber stamp (issue #875).
# catalog: merge-gate-sequencing — Decide whether a bot's `APPROVED` on a SHA is real review coverage or a hollow rubber stamp
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
#                              a commit other than the one it approved, AND that
#                              reviewer left no HEAD-anchored inline comments.
#                              Inline comments (commit_id AND original_commit_id
#                              == HEAD) are first-party evidence of which SHA
#                              was read, so they supersede a stale status table
#                              (inventory #416 / this repo #1380). A long
#                              approval body or SHA-less descriptive comment
#                              does NOT clear the mismatch — that would re-open
#                              the rubber-stamp hole and the #927 launder.
#   4. pre_run_approval      — the reviewer publishes a MACHINE-READABLE record
#                              of its own analysis of this commit, and the
#                              APPROVED does not sit inside it: the run had not
#                              started when the approval was posted, or has not
#                              finished yet. Same ordering violation as (1), but
#                              read off the reviewer's own structured data
#                              instead of inferred from prose — and therefore
#                              NOT suppressible by external evidence (issue
#                              #1365; see $pre_run for why). One narrow
#                              redemption: see redeemed_by_clean_run below.
#   5. substantive           — review body OR inline comments on HEAD OR a
#                              same-SHA status comment naming HEAD OR a long
#                              descriptive comment in the current review round.
#                              Never body length on its own, and never a comment
#                              whose content is the reviewer declining to review
#                              or a fixed run-start/completion marker.
#   6. seconds_after_push    — reported only. Timing corroborates, never decides.
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
#     "issue_comments":  [ … ],            # issues/{N}/comments (conversation)
#     "resolved_comment_ids": [ 123, … ]   # optional; REST ids of inline
#                                          # comments whose review thread is
#                                          # resolved (GraphQL databaseId)
#   }
#
# `resolved_comment_ids` is OPTIONAL and defaults to []. Omitting it reproduces
# the pre-#1632 behaviour exactly: an id absent from the set reads as "thread
# unresolved or unknown", which still counts as a finding. Only callers holding
# the GraphQL reviewThreads data supply it (merge-gate.sh; escalate-review.sh
# via pr-state.sh, which already fetches comment databaseId).
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
#        "pre_run_approval": false, "run_has_findings_on_head": false,
#        "redeemed_by_clean_run": false, "run_started_at": "…",
#        "run_finished_at": "…", "run_done": true,
#        "substantive": true, "counts_as_coverage": true,
#        "disqualified_by": [], "seconds_after_push": 214
#     } },
#     "substantive":       ["coderabbitai[bot]"],  # approvers that count as coverage
#     "hollow":            ["codeant-ai[bot]"],    # approved, but nothing read it
#     "mismatched":        [ … ],                  # approved X, self-reports Y
#     "inverted":          [ … ],                  # approved before its own run started
#     "capability_failed": [ … ],                  # said it could not review, approved anyway
#     "pre_run":           [ … ],                  # approved outside its own recorded run
#     "redeemed_by_clean_run": [ … ],              # of those, the ones a completed
#                                                  # clean run on HEAD redeemed
#     "corroborating":     ["cursor[bot]"]         # substantive non-approvers on HEAD
#   }
#
# Signal details:
#
#   body_len                  length of the LATEST APPROVED review body on HEAD
#   inline_comments_on_head   inline diff comments anchored to HEAD (commit_id AND
#                             original_commit_id == HEAD, so comments GitHub
#                             "moved" forward on force-push do not count)
#   run_started_at            from a STRUCTURED run marker the reviewer publishes
#   run_finished_at           for HEAD — currently CodeAnt's
#   run_done                  `<!-- codeant-review-status:[…] -->` payload, which
#                             records {commit, started, finished, done} per
#                             commit it has touched (issue #1365). Empty/null
#                             when that reviewer publishes no such record for
#                             HEAD, which is every other reviewer today. The
#                             payload's timestamps are naive UTC, so they are
#                             canonicalised onto the same `Z` spelling as review
#                             timestamps before any compare.
#   pre_run_approval          a structured HEAD run marker exists and the
#                             APPROVED does not sit inside that run: the run is
#                             not `done`, or submitted_at < run_started_at.
#                             Reported raw — it stays true when redeemed.
#   run_has_findings_on_head  that reviewer left a non-APPROVED review or a
#                             BLOCKING inline comment on HEAD.
#
#                             Review-state findings stay SHA-wide, read by
#                             PRESENCE on the commit_id-scoped index and never by
#                             ordering a review object against the run window:
#                             CodeAnt freezes submitted_at on in-place edits
#                             (#876), so a timestamp test on a REVIEW cannot fire
#                             for the reviewer this term exists to judge.
#
#                             The INLINE-comment term is scoped to the governing
#                             run (issue #1632). An inline comment on HEAD counts
#                             only when its created_at falls inside that run"s
#                             started->finished window, OR its thread is still
#                             unresolved (or its resolution is unknown, which is
#                             the default). A finding an EARLIER run posted on
#                             this same SHA that was then declined-with-evidence
#                             and RESOLVED is therefore not carried into a later
#                             clean run"s verdict — otherwise the gate"s own
#                             stated remedy ("comment @codeant-ai review") could
#                             never redeem a hollow approval, because a re-run
#                             that finds nothing posts nothing new (observed on
#                             PR #1612 at da2acd8 and PR #1627 at d4ac833, both
#                             forced down to Greptile). created_at is safe here
#                             where submitted_at is not: it is the posting time
#                             of a distinct comment object, not a PATCHed-in-place
#                             verdict. With no governing run marker the window
#                             test cannot apply and every HEAD inline comment
#                             counts, exactly as before.
#   redeemed_by_clean_run     the ONE narrow exception to "pre_run_approval is
#                             not suppressed by external evidence" (issue
#                             #1432). True when pre_run_approval holds AND the
#                             same reviewer's run marker for THIS SHA reached
#                             `done` AND run_has_findings_on_head is false AND
#                             no other disqualifier survives. It drops both
#                             `pre_run_approval` and `no_substantive_footprint`
#                             from disqualified_by, so counts_as_coverage flips
#                             through the ordinary rule and every consumer
#                             inherits the verdict with no tag-specific logic.
#                             Rationale: some repos see CodeAnt emit APPROVED
#                             only as a pre-run stub, post findings as a later
#                             COMMENTED review, and post NOTHING when the run is
#                             clean — so a clean pass could never produce a
#                             gate-valid approval and the CR path deadlocked
#                             (still-point PR #696, this repo PR #1454).
#                             Re-triggering never fixes it: the frozen
#                             submitted_at can never move past the run start.
#                             NEVER redeemed by: reviewer identity, an in-flight
#                             run, a run that produced any finding on HEAD, an
#                             absent or unparseable run record, or prose.
#   status_comment_names_head a conversation comment by that bot containing the
#                             HEAD SHA (full, or a >=7-char token that
#                             prefix-matches HEAD — hex OR all-decimal, issue
#                             #894) and >= min_chars long, and — when the comment
#                             IS a structured run-status table — whose HEAD row
#                             is `done` (issue #1365). An in-flight row is a run
#                             marker, and a run marker is not evidence that any
#                             diff was read; letting it through is what made the
#                             pre-analysis stub self-certifying. No
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
#                             matching HEAD, unless that bot also left inline
#                             comments anchored to HEAD (inventory #416 / #1380).
#                             SHA-like = \b[0-9a-f]{7,40}\b with at
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
#   counts_as_coverage        approved AND (substantive OR redeemed_by_clean_run)
#                             AND none of the four disqualifiers above.
#                             self_report_mismatch is omitted from that set when
#                             inline_comments_on_head > 0 (inventory #416 / this
#                             repo #1380).
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
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

MIN_CHARS="${MERGE_GATE_SUBSTANCE_MIN_CHARS:-40}"
REVIEWERS="coderabbitai[bot],codeant-ai[bot]"
CORROBORATORS="cursor[bot],greptile-apps[bot],graphite-app[bot]"

print_usage() {
  awk 'NR == 1 { next } /^#/ { print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
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

  # Structured run markers carry NAIVE timestamps — CodeAnt writes
  # "2026-08-26T16:16:40.854977" with no zone at all — while every review
  # timestamp they are compared against ends in "Z". Left alone, the compare is
  # wrong in the silent direction: "…T16:16:13" is a strict PREFIX of
  # "…T16:16:13Z", so it sorts BEFORE it, and an approval landing in the same
  # second as its own run start would read as postdating it. The values are UTC
  # (confirmed against the live PR #676 payload, where the documented 27-second
  # gap only holds under that reading), so canonicalise onto the same spelling
  # and let one lexicographic rule cover both sides. A marker that already
  # carries a zone is left alone rather than double-suffixed.
  #
  # A value that is not a timestamp at all yields "" rather than a canonicalised
  # nonsense string (CodeRabbit review of this PR). Every consumer compares these
  # LEXICOGRAPHICALLY, so garbage does not fail loudly — it sorts. `started: "zz"`
  # canonicalised to "zzZ", which every real timestamp sorts before, and that
  # silently inverted two guards at once: `$pre_run` read every approval as
  # predating the run, and the issue #1632 window disjunct matched nothing, which
  # withdrew the anti-laundering term that makes resolving a finding the governing
  # run itself posted fail to launder it. Redemption was then granted off a run
  # record that never described a real run.
  #
  # Blanking is the conservative repair. It does TWO separate things, and the
  # distinction matters (CodeRabbit CLI review of this PR):
  #
  #   * The blank itself lands on a degrade path the module already documents
  #     rather than inventing one — "" is exactly the "done run with no parseable
  #     `started`" shape $pre_run handles at its `started == ""` branch, and it
  #     also drops the row to the bottom of run_marker_head"s max_by, so a
  #     well-formed sibling run governs instead of the garbage one.
  #   * Blanking ALONE would then be too permissive, because a sole garbage row
  #     would stop pre_run_approval from firing at all. So run_markers carries a
  #     separate `ts_unusable` flag for a field that was SUPPLIED but unreadable,
  #     as opposed to omitted, and $pre_run treats that as true while
  #     $redeem_shape bars it outright — the rule stated below at $redeem_shape,
  #     that an absent or unparseable run record never redeems.
  #
  # Blanking rather than DROPPING the row is deliberate: dropping would take an
  # in-flight ($runmark.done false) record with a malformed `started` out of
  # $runmark entirely, turning a blocking in-flight verdict into no verdict at
  # all, which is the permissive direction. A blanked `finished` likewise leaves
  # the window open-ended, which only ever counts MORE comments as findings.
  # Pinned by (s5)/(s5a)/(s5b).
  #
  # The accepted terminator is `Z` ONLY, and that is a correctness requirement,
  # not fussiness (CodeRabbit CLI review of this PR). These values are compared
  # lexicographically against `Z`-spelled review timestamps and ordered by max_by,
  # so a real non-UTC offset would be silently mis-ordered — "…T16:25:00+05:00"
  # sorts BEFORE "…T16:20:00Z" because "+" < "Z", not after it, as the instants
  # actually run. canon_ts has already folded the only zero offsets observed in
  # the wild (`+00:00`, `+0000`) onto `Z`, and CodeAnt writes naive UTC, so no
  # legitimate payload is rejected; a genuinely offset-bearing one becomes
  # ts_unusable and blocks rather than sorting wrongly. Seconds stay optional so
  # the check rejects garbage rather than narrowing the shapes actually observed.
  def canon_marker_ts:
    (. // "") | tostring
    | if . == "" then ""
      else canon_ts
           | (if test("(Z|[+-][0-9]{2}:?[0-9]{2})$") then . else . + "Z" end)
           | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$")
             then . else "" end
      end;

  (.head_sha // "" | ascii_downcase)  as $sha
  | ((.push_ts // "") | canon_ts)     as $push
  | (.reviews // [])                  as $reviews
  | (.pr_comments // [])              as $inline
  | (.issue_comments // [])           as $convo
  # Issue #1632. Optional; see the input-schema note in the header. Built as a
  # lookup OBJECT rather than kept as an array so the membership test below is
  # O(1) per inline comment instead of O(threads). Ids are stringified on both
  # sides so a JSON number and its string spelling cannot silently miss.
  | ( (.resolved_comment_ids // []) | map(tostring)
      | reduce .[] as $rid ({}; .[$rid] = true) )    as $resolved_ids
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
      # UUID-stripped text for rule 1 only (issues #917, #1248). CodeRabbit
      # embeds invocation UUIDs in HTML comments in two known shapes:
      #   "request id 9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6" (issue #917)
      #   "review command invocation: df440ae1-9ab9-4b17-bb0a-caae8c17534a"
      #     (issue #1248, auerbachb/inventory issue #408, PR #403)
      # A hyphen is a non-word character, so the UUID"s hex groups independently
      # satisfy rule 1"s shape (7-40 chars, at least one a-f letter) and get
      # misread as SHAs the bot claims to have reviewed. Each match is replaced
      # with a space, not stripped to empty, so a UUID sitting between two
      # genuine tokens cannot merge them into a new false one. Rules 2-3 are
      # untouched: rule 2 is safe regardless because it additionally requires
      # a prefix match against the real $sha, and rule 3 only admits complete
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

    # ---- Structured run markers (issue #1365) -------------------------------
    #
    # CodeAnt maintains ONE in-place-edited conversation comment, "🤖 CodeAnt AI
    # — Review Status", whose visible table has a row per commit it has touched.
    # Behind that table it embeds the same data machine-readably:
    #
    #   <!-- codeant-review-status:[{"label":"Reviewed your PR",
    #        "commit":"bb7d4e2…","started":"2026-08-26T16:16:40.854977",
    #        "finished":"2026-08-26T16:19:51.141986","done":true}, …] -->
    #
    # Full 40-char SHA, per-commit started/finished/done. Everything needed to
    # ask whether an approval was produced by the analysis it claims to report
    # was already on the PR; nothing read it. Two consequences followed, both
    # live on still-point PR #676: the in-flight row satisfied
    # status_comment_names_head (the table contains HEAD"s SHA and clears
    # min_chars), which set external_evidence_on_head, which suppressed BOTH
    # temporal_inversion and capability_failure — a run marker certifying
    # itself, the exact circularity the header warns against. And the prose
    # marker regex never matched CodeAnt"s wording ("Reviewing your PR" has no
    # "is " before it), so $marker was structurally null for that bot on every
    # PR and temporal_inversion was dead code there regardless.
    #
    # Scoped to STRUCTURED markers on purpose. The prose regex, $marker,
    # $descriptive_ev and every #875 shape are left byte-for-byte alone: this
    # adds a discriminator that reads data the reviewer volunteered, rather than
    # widening a heuristic that guesses from wording.
    #
    # Parsing is total-failure-tolerant by construction — `fromjson?` swallows
    # an unparseable payload and the whole chain yields [], which lands the
    # reviewer back on exactly today"s behaviour. The capture runs to the first
    # `-->` (lazy), so a comment carrying several HTML comments cannot merge
    # them; whitespace is trimmed because the marker is pretty-printed in some
    # revisions and inline in others.
    def run_markers:
        [ ((. // "") | scan("<!--[[:space:]]*codeant-review-status:([\\s\\S]*?)-->"))
          | (if type == "array" then (.[0] // "") else . end)
          | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
          | (fromjson? // empty)
          | (if type == "array" then .[] else empty end)
          | select(type == "object")
          | { commit:   ((.commit // "") | tostring | ascii_downcase),
              label:    ((.label // "") | tostring),
              started:  (.started  | canon_marker_ts),
              finished: (.finished | canon_marker_ts),
              done:     (.done == true),
              # A field the bot SUPPLIED but that is not a timestamp, as opposed
              # to one it simply omitted. canon_marker_ts blanks both, and the
              # two must not be conflated: an omitted `started` is the documented
              # pre-#1365 degrade ("judge the reviewer as before"), while a
              # supplied-but-garbage one is a record actively claiming something
              # unreadable, which cannot vouch for anything. Carried as its own
              # flag so $pre_run and $redeem_shape can each say so explicitly
              # rather than inferring it from an empty string.
              ts_unusable:
                (((((.started  // "") | tostring) != "") and ((.started  | canon_marker_ts) == ""))
                 or ((((.finished // "") | tostring) != "") and ((.finished | canon_marker_ts) == ""))) }
          | select(.commit != "") ];

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
            # This comment"s structured run record FOR HEAD, or null when it
            # carries no such payload or the payload covers only other commits.
            # SELECTED BY CONTENT, NEVER BY LIST POSITION (issue #1419). The
            # first cut took `| last` on the belief that the payload lists
            # commits in the order CodeAnt touched them; live PR #1378 refuted
            # that — CodeAnt PREPENDS each new run row, newest first (three
            # rows for one SHA ordered 16:35, 16:31, 15:48, and the 5-row
            # visible table dropped its oldest commit when a new row arrived),
            # so `last` returned the OLDEST run and the intended guarantee
            # inverted: a stale completed run was exactly what vouched for a
            # re-review still in flight, and a fresh stub posted at a re-run"s
            # start cleared pre_run_approval against the old row"s `started`.
            # Vendor insertion order is not a contract in either direction, so
            # no positional pick can be right; the row is chosen by its own
            # data instead. An in-flight row (done == false) outranks every
            # completed one — preserving the retained intent that a completed
            # earlier run must not vouch for an analysis that is currently
            # back in flight — and otherwise the latest `started` wins.
            # max_by orders false < true, so [(.done | not), .started] ranks
            # in-flight rows first and breaks the remainder on the later
            # start; on an empty match list max_by yields null, preserving
            # the "no record for HEAD" shape. Prefix matching in both
            # directions mirrors tokens_name_head, so a short SHA in the
            # payload still matches.
            run_marker_head: (
              [ ($b | run_markers)[]
                | . as $m
                | select(($sha | length) > 0
                         and (($sha | startswith($m.commit)) or ($m.commit | startswith($sha)))) ]
              | max_by([(.done | not), .started])),
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
            # Recognized CodeRabbit command-invocation metadata comments. These
            # are auto-generated when CR processes a review command and contain
            # only "Action performed" / "Full review finished" boilerplate plus
            # an HTML-comment UUID tag — no review substance. Two known shapes
            # (issues #917, #1248):
            #   "request id [uuid]"                     (issue #917 shape)
            #   "review command invocation: [uuid]"     (issue #1248 shape)
            # Excluded from $descriptive_ev so that a run-start marker + an
            # invocation-only comment cannot grant counts_as_coverage on a
            # hollow approval (CodeAnt finding, PR #1280).
            #
            # Both conditions must hold (CodeRabbit finding, PR #1280):
            #   1. The invocation phrase appears inside a COMPLETE HTML comment
            #      (<!-- -->), and that comment contains a full 8-4-4-4-12 UUID
            #      with no adjacent hex digit on either side. scan extracts only
            #      complete HTML comment blocks (preventing the pattern from
            #      crossing --> into prose outside a comment), the full 8-4-4-4-12
            #      UUID is required (rejecting UUID-less phrases and partial UUID
            #      prefixes), and the trailing (?![0-9a-f]) lookahead prevents an
            #      overlong hex run (e.g. 38-char last group) from matching the
            #      first 12 characters.
            #   2. After applying strip_echoed($cts) to remove echoed author lines,
            #      then stripping HTML comments and tags, the residual prose is
            #      below $min_chars. Using strip_echoed first prevents a >=40-char
            #      author-echoed line from artificially inflating the residual and
            #      defeating the filter — a comment is only "invocation-only" when
            #      the reviewer-authored residual (not the echo noise) is short.
            invocation_comment: (
              ([$b | ascii_downcase | scan("<!--[\\s\\S]*?-->")]
                | any(test("(?:review command invocation: ?|request id )[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])"; "m")))
              and
              (($b | ascii_downcase | strip_echoed($cts) | gsub("<!--.*?-->"; " "; "m") | gsub("<[^>]+>"; " ") | gsub("[[:space:]]+"; " ") | ltrimstr(" ") | rtrimstr(" ") | length) < $min_chars)),
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
              ts: (((.updated_at // .created_at) // "") | canon_ts),
              # created_at (NOT updated_at) is the run-window dimension: the
              # question is which run POSTED this comment, and an edit made
              # afterwards must not move it into a later run"s window.
              created: (((.created_at // .updated_at) // "") | canon_ts),
              # REST comment id, stringified to match $resolved_ids. Missing
              # ("") can never be in the set, so it reads as unresolved and
              # still counts — the conservative direction.
              cid: (((.id // "") | tostring)) } ] ) as $iidx

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
        #
        # An IN-FLIGHT run-status table is not one of those status comments
        # (issue #1365). Its HEAD row exists the moment analysis is queued, so
        # it clears min_chars and contains HEAD"s SHA while nothing has been
        # read yet — the comment says "work began", which the header already
        # rules out as self-evidence, and admitting it here is what let a
        # pre-analysis stub manufacture its own external evidence. Only a
        # structured payload can trip this: `run_marker_head` is null both for
        # reviewers that publish none and for a payload that does not cover
        # HEAD, so every pre-#1365 shape — CodeRabbit"s walkthrough, CodeAnt"s
        # completed #876 re-review table — is admitted exactly as before.
        | ( [ $mine[]
              | select(.len >= $min_chars and .names_head and (.failure | not)
                       and (.run_marker_head == null or .run_marker_head.done)) ] ) as $status_ev
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
        # even when this value is true. The only suppressor is HEAD-anchored
        # inline comments, applied at $mismatch (inventory #416 / #1380).
        | ( $marker != null and
            ([ $mine[]
               | select(.authored_len >= $min_chars
                        and (.failure | not)
                        and (.marker | not)
                        and (.completion_marker | not)
                        and (.invocation_comment | not)
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
        # HEAD-anchored inline comments suppress the mismatch (inventory #416 /
        # #1380): they are first-party evidence of which SHA was read
        # (commit_id AND original_commit_id == HEAD), so a stale CodeAnt
        # status table — which records only push-triggered auto-reviews — must
        # not veto a genuine manual review. A long approval body or SHA-less
        # descriptive comment does NOT suppress it (rubber-stamp / #927).
        | ( [ $mine[] | select((.tokens | length) > 0) ]
            | sort_by(.created) | last )                                   as $selfrep
        | ( $selfrep != null and ($selfrep.names_head | not)
            and (($inl | length) == 0) )                                   as $mismatch

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

        # This reviewer"s structured run record for HEAD, taken from its LATEST
        # comment carrying one — the table is edited in place, so .ts
        # (updated_at) is the dimension that tracks its current contents.
        | ( [ $mine[] | select(.run_marker_head != null) ]
            | sort_by(.ts) | last | .run_marker_head )                     as $runmark

        # Pre-run approval (issue #1365): the approval is not inside the run
        # that supposedly produced it. Two rejected shapes, one accepted:
        #
        #   done == false            -> the analysis for HEAD is still running.
        #                               A verdict cannot precede its own work.
        #   ap_ts < started          -> the approval predates the run start. All
        #                               five CodeAnt APPROVEDs on PR #676 are
        #                               this shape, by 27s to 6m54s.
        #   done and ap_ts >= started -> counts.
        #
        # The lower bound is the run START, not its finish, and that is
        # deliberate: CodeAnt stamps `finished` when it rewrites the status
        # table, AFTER posting its verdict object (observed on a5670b7 —
        # COMMENTED 16:12:07, finished 16:12:21), so a finish-based bound would
        # reject genuine approvals. `done` guarantees a verdict exists;
        # `>= started` guarantees this run produced it. Both together reject
        # every stub without touching the genuine shape.
        #
        # NOT suppressed by $ext_substantive, unlike $inversion and $fail. Those
        # two suppress because external work redeems an approval whose body is
        # merely thin. Here the suppressing evidence WAS the marker comment
        # itself — that circle is the defect — and more fundamentally, evidence
        # that the reviewer eventually did the work does not make an approval
        # posted before that work a report of it. The correct resolution is the
        # verdict CodeAnt posts afterwards, which arrives as its own review
        # object and is evaluated on its own terms.
        #
        # Degrades rather than blocks when the record is unusable: no marker for
        # HEAD, or a done run with no parseable `started`, yields false and the
        # reviewer is judged exactly as it was pre-#1365.
        # ts_unusable is checked BEFORE done: a record whose own timestamps are
        # unreadable cannot place the approval inside or outside it, and the
        # conservative reading of an unprovable ordering is the blocking one.
        # It is NOT folded into the `started == ""` branch below, which stays
        # the pre-#1365 degrade for a field the bot never supplied.
        | ( if ($ap == null or $runmark == null or $ap_ts == "") then false
            elif ($runmark.ts_unusable == true) then true
            elif ($runmark.done | not) then true
            elif ($runmark.started == "") then false
            else ($ap_ts < $runmark.started)
            end )                                                          as $pre_run

        # Did this reviewer produce FINDINGS on HEAD, from the run that is being
        # judged? $ridx and $iidx are already filtered to HEAD, so anything on
        # either index came from a run on this commit — but a SHA can hold more
        # than one run, and issue #1632 is the case where it does.
        #
        # REVIEW-STATE findings stay SHA-wide, detected by PRESENCE alone and
        # never by ordering a review object against the run window. A
        # submitted_at comparison there would be worse than imprecise: CodeAnt
        # PATCHes its review objects in place and never refreshes submitted_at
        # (#876), so the timestamps of the very reviewer this term exists to
        # judge are frozen and unorderable. A lingering non-APPROVED review
        # therefore still blocks redemption, unconditionally.
        #
        # INLINE-comment findings are scoped to the governing run (issue #1632).
        # An inline comment counts when EITHER its created_at falls inside
        # $runmark"s started->finished window, OR its thread is not known to be
        # resolved. It is excluded only when it is BOTH outside the window AND
        # resolved — i.e. a finding an earlier run on this same SHA posted, that
        # was answered and closed out. Without that scoping the gate"s own
        # documented remedy is unreachable: a re-run triggered by
        # "@codeant-ai review" that finds nothing posts nothing new, so the
        # earlier comments keep run_has_findings_on_head true forever and no
        # clean run can ever redeem the stub (PR #1612 at da2acd8, PR #1627 at
        # d4ac833 — both fell to Greptile with the stickiness that brings).
        #
        # created_at is a legitimate ordering dimension here where submitted_at
        # is not: it stamps a distinct comment OBJECT at the moment it was
        # posted, rather than a verdict the bot rewrites in place. And the
        # window test can only ever ADD findings — an unresolved thread counts
        # regardless — so a bot that did freeze a comment timestamp lands on the
        # resolution branch, not on a false clean.
        #
        # $resolved_ids defaults to {} for callers that pass no thread data, and
        # an empty set makes every inline comment unresolved, which reproduces
        # the pre-#1632 "any inline comment counts" behaviour byte for byte.
        # With $runmark null there is no window to test and the same holds.
        #
        # Deliberately NOT filtered through fresh_review, unlike
        # $other_review_len. A COMMENTED review that GitHub re-pointed onto HEAD
        # cannot be proven to belong to this round, and the conservative reading
        # of an unprovable finding is that it counts — this term only ever
        # WITHHOLDS the redemption below.
        #
        # An explicit allow-list of the two states that CARRY findings, not
        # `!= "APPROVED"` (CodeRabbit CLI review of this PR). The GitHub review
        # states are exactly APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED
        # and PENDING, and the last two are not findings: PENDING is an
        # unsubmitted draft, and DISMISSED is a review this repo"s own tooling
        # ruled obsolete — `/fixpr` runs dismiss-stale-bot-changes.sh after every
        # push. Since GitHub re-points commit_id onto HEAD across a conflict-free
        # rebase, a dismissed review can arrive carrying HEAD"s SHA; counting it
        # would block redemption permanently on any PR that ever had one, which
        # is the exact stranding the dismissal exists to clear. A missing or
        # unrecognised state likewise does not block — inventing a blocker from
        # unusable data is the failure mode #836 warns about.
        | ( (([ $ridx[]
                | select(.login == $login
                         and (.state == "COMMENTED" or .state == "CHANGES_REQUESTED")) ]
              | length) > 0)
            or (([ $inl[]
                   | select(
                       # No governing run record: the window test cannot apply,
                       # so every HEAD inline comment counts (pre-#1632 rule).
                       ($runmark == null)
                       # Posted by the governing run itself. $runmark.started /
                       # .finished are already canonicalised onto the `Z`
                       # spelling by canon_marker_ts at parse time, so these are
                       # like-for-like string compares. A run still in flight
                       # carries an empty `finished`, which leaves the window
                       # open-ended rather than empty.
                       or ((($runmark.started // "") != "") and (.created != "")
                           and (.created >= $runmark.started)
                           and ((($runmark.finished // "") == "")
                                or (.created <= $runmark.finished)))
                       # Not known to be resolved — unresolved, or the caller
                       # supplied no thread data for it.
                       or (($resolved_ids[.cid] // false) | not)) ]
                 | length) > 0) )                                          as $run_has_findings

        # Redemption of a pre-run approval (issue #1432) — the one narrow
        # exception to "$pre_run is not suppressed by external evidence".
        #
        # The disqualifier above conflates two shapes. A stub with no run behind
        # it is a rubber stamp and must block. But CodeAnt now emits APPROVED
        # ONLY as a pre-run stub on some repos: findings arrive later as a
        # COMMENTED review, and a CLEAN run produces no further review object at
        # all. On those repos a clean pass could never yield a gate-valid
        # approval, so a perfectly-reviewed PR deadlocked with no exit but a paid
        # Greptile escalation or an admin merge (still-point PR #696; this repo
        # PR #1454). Re-triggering the bot is not a workaround and never will
        # be — the frozen submitted_at cannot move forward past the run start.
        #
        # What redeems: the reviewer"s OWN machine-readable record of this
        # commit reaching done, with zero findings on this commit. That is not
        # the approval vouching for itself and it is not the marker vouching for
        # the approval — it is a completed analysis of HEAD whose result was
        # "nothing to report", which is the same claim the approval makes.
        #
        # What never redeems: reviewer identity, an in-flight run ($runmark.done
        # false, which is the OTHER $pre_run shape), a run that produced any
        # finding on HEAD, an absent or unparseable run record, or any amount of
        # external prose. Each of those leaves $pre_run in $disq exactly as
        # before, so the #875 rubber-stamp guard and the #1365 in-flight guard
        # are untouched in the refuse direction.
        | ( $pre_run
            and $runmark != null
            and ($runmark.ts_unusable != true)
            and ($runmark.done == true)
            and ($run_has_findings | not) )                                as $redeem_shape

        # When the shape holds, BOTH tags leave $disq. `pre_run_approval` because
        # the clean run is the corroboration it was missing;
        # `no_substantive_footprint` because that completed run IS the footprint —
        # withholding coverage for want of evidence while holding the reviewer"s
        # own completed analysis of HEAD would just relocate the same deadlock.
        # The raw booleans are still reported, so an audit sees the full shape.
        | ( [ (if ($ap != null and ($substantive | not) and ($redeem_shape | not)) then "no_substantive_footprint" else empty end),
              (if ($ap != null and $mismatch) then "self_report_mismatch" else empty end),
              (if $inversion then "temporal_inversion" else empty end),
              (if ($pre_run and ($redeem_shape | not)) then "pre_run_approval" else empty end),
              (if $cap_fail then "capability_failure" else empty end) ] )  as $disq

        # Reported as redeemed only when redemption actually decided the
        # outcome: an unrelated disqualifier still standing (temporal_inversion,
        # self_report_mismatch, capability_failure) keeps the reviewer blocked
        # and this flag false, so the tag can never be read as "gate cleared"
        # when it was not.
        | ( $redeem_shape and ($disq | length) == 0 )                      as $redeemed

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
              # Raw, and deliberately still true when redeemed: the ordering
              # violation really did happen, and an audit reading only
              # disqualified_by would otherwise lose the shape entirely.
              pre_run_approval:          $pre_run,
              run_has_findings_on_head:  $run_has_findings,
              redeemed_by_clean_run:     $redeemed,
              run_started_at:            (($runmark.started) // ""),
              run_finished_at:           (($runmark.finished) // ""),
              # null (not false) when this reviewer published no structured run
              # record for HEAD, so a consumer can tell "no record" from "record
              # says the run is unfinished".
              run_done:                  (if $runmark == null then null else $runmark.done end),
              substantive:               $substantive,
              # `$redeemed` is an alternative to `$substantive`, never to the
              # empty-$disq requirement: it can only satisfy the "something read
              # this commit" half, and it is itself false whenever any
              # disqualifier survives.
              counts_as_coverage:        ($ap != null and ($substantive or $redeemed) and ($disq | length) == 0),
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
        # Reports the SHAPE, so a redeemed approver appears here AND in
        # .substantive[]. Nothing gates on this bucket — .hollow[] is the
        # discounted set — and an audit that could not see a redeemed pre-run
        # approval at all would be blind to exactly the case worth watching.
        pre_run:           [ $map | to_entries[] | select(.value.pre_run_approval) | .key ],
        redeemed_by_clean_run:
                           [ $map | to_entries[] | select(.value.redeemed_by_clean_run) | .key ],
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
