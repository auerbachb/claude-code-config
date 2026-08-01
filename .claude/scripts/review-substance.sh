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
#                              same-SHA status comment naming HEAD. Never body
#                              length on its own, and never a comment whose
#                              content is the reviewer declining to review.
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
#        "status_comment_names_head": true, "status_comment_shas": ["…"],
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
#                             manufacture a mismatch. See sha_tokens for why the
#                             code-span rule can only ever withhold coverage.
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
#                             OR status_comment_names_head
#   external_evidence_on_head substantive footprint OTHER than the approval body
#                             (inline comments, or a status comment naming HEAD);
#                             what suppresses a temporal_inversion verdict
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
  | def sha_tokens:
      ((. // "") | ascii_downcase) as $btxt
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
      #      removed, so it cannot swallow a later valid close.
      #   4. Four-space-indented lines — \n    [^\n]* matches each indented line
      #      (the leading newline is part of the match; the line-anchor flag "s"
      #      is not used because it does not do what PCRE multiline would do).
      | ($btxt
         | gsub("```.*?```"; " "; "m")
         | gsub("~~~.*?~~~"; " "; "m")
         | gsub("```.*"; " "; "m")
         | gsub("\n    [^\n]*"; " "; "m")
        ) as $unfenced
      | [ ( $btxt | scan("\\b[0-9a-f]{7,40}\\b") | select(test("[a-f]")) ),
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
    ( [ $convo[]?
        | (.body // "") as $b
        | (($b | sha_tokens)) as $tok
        | { login:   (.user.login // ""),
            body:    $b,
            len:     ($b | length),
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
        # Substance that exists INDEPENDENTLY of the approval object itself:
        # inline comments anchored to HEAD, a status comment naming HEAD, or a
        # substantive non-APPROVED review on HEAD. The approval"s own body is
        # excluded on purpose — see $inversion below.
        | ( (($inl | length) > 0) or $names_head
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

        # EARLIEST post-push run-start marker. Earliest, not latest: a re-review
        # kicked off AFTER a genuine approval would otherwise look inverted.
        #
        # ">=", not ">" — the push second is INCLUSIVE, matching fresh_review
        # above (BugBot review on c90b32a, PR #883). canon_ts has already
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
              other_review_body_len:     $other_review_len,
              external_evidence_on_head: $ext_substantive,
              status_comment_shas:       (($selfrep.tokens // []) | unique),
              self_report_mismatch:      ($ap != null and $mismatch),
              temporal_inversion:        $inversion,
              run_start_marker_at:       (($marker.created) // ""),
              capability_failure:        $cap_fail,
              capability_failure_text:   (($fail.body // "") | .[0:160]),
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
