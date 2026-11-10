# deferred-refs.jq — the follow-up-issue link parser, shared (issue #1810).
#
# One parser for "does this review-thread reply defer the finding to a
# follow-up issue?", used by two callers that must agree:
#   merge-gate.sh            the deferred-findings gate (issue #1727)
#   lib/review_ledger.py     the review-stack-audit verdict classifier (#1810)
# Load it with `jq -L <this dir> 'include "deferred-refs"; ...'`. The rules are
# documented in .claude/reference/review-policy.md "What counts as a follow-up
# reply"; change them here and both callers move together.
#
# Both functions take ONE reply body (a string) as input. Choosing which
# replies qualify (after the first comment, a `User` author) stays with each
# caller: the gate reads only unresolved threads, the ledger reads every one.

# Quoted lines (`> ...`) removed, each replaced by a newline, so a reply that
# quotes a bot's finding cannot borrow a number, a phrase, or a marker the bot
# wrote. Line structure around the quote is kept.
def strip_quoted_lines:
  gsub("(^|\n)[ \t]*>[^\n]*"; "\n");

# The same-repo issue numbers this reply references, as an array in order of
# appearance (duplicates kept; callers `unique` as they need). `$repo` is
# `owner/name`, compared case-insensitively. Accepted forms: `#N`,
# `owner/repo#N` naming this repo, and `https://github.com/owner/repo/issues/N`.
# N is capped at nine digits so `tonumber` stays exact; a longer number never
# matches. A `/pull/` URL, another repo, and a number glued to a word or a path
# (`abc#12`, `a/b/c#12`) never match. Quoted lines are skipped.
def deferred_refs($repo):
  ($repo | ascii_downcase) as $self
  | [ strip_quoted_lines
      | scan("(?<![A-Za-z0-9_./-])https?://(?:www\\.)?github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]{1,9})(?![A-Za-z0-9_])|(?<![A-Za-z0-9_./-])([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]{1,9})(?![A-Za-z0-9_])|(?<![A-Za-z0-9_./&#-])#([0-9]{1,9})(?![A-Za-z0-9_])")
      | if .[2] != null then {r: ((.[0] + "/" + .[1]) | ascii_downcase), n: .[2]}
        elif .[5] != null then {r: ((.[3] + "/" + .[4]) | ascii_downcase), n: .[5]}
        else {r: $self, n: .[6]} end
      | select(.r == $self)
      | (.n | tonumber)
      | select(. > 0) ];
