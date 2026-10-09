# pr-state-unmarked-replies.jq — advisory count of agent replies to review-bot
# inline threads that carry no review-verdict marker (issue #1842).
#
# Canonical program for pr-state.sh's top-level `unmarked_replies` integer.
# Input: the projected REST inline-comment array (`.comments.inline`), each
# element carrying {id, in_reply_to_id, user: {login, type, id}, body}.
# Output: one integer.
#
# A comment counts when ALL hold:
#   - it is a reply (`in_reply_to_id` non-null) whose target comment was written
#     by one of the five review-bot logins below;
#   - its author is a GitHub `User` account whose login does not end in `[bot]`;
#   - its body has no line, outside a fenced code block, that starts with
#     `<!-- review-verdict: fixed|deferred|declined ` — the marker
#     reply-thread.sh --verdict appends as its own line. A quoted (`> …`) or
#     inline-code marker does not start the line, so it does not count.
#
# ADVISORY ONLY. Nothing gates on this count: merge-gate.sh never reads it and
# /wrap prints it without routing it to /fixpr. It is a proxy — a human typing
# on the agent's account is counted as an agent reply, and a PR-level fallback
# reply (reply-thread.sh's 404 path) is not an inline reply, so it is never
# counted (the ledger's own gap, issue #1829).
# Mechanism: .claude/reference/review-stack-audit.md §The marker.
#
# The bot list mirrors pr-state.sh's `$botlist`; pr-state-unmarked-replies.test.sh
# asserts the two stay equal.

def review_bot_logins:
  ["coderabbitai[bot]","cursor[bot]","codeant-ai[bot]","greptile-apps[bot]","graphite-app[bot]"];

# True when a marker line sits outside every fenced block. Fences follow
# CommonMark: an opener of 3+ backticks or tildes (up to 3 leading spaces)
# closes on a line holding only a run of the same character at least as long;
# an unclosed fence runs to the end of the body.
def has_verdict_marker:
  reduce ((. // "") | split("\n")[] | sub("\r$"; "")) as $line (
    {fence: null, found: false};
    if .found then .
    elif .fence == null then
      ($line | capture("^ {0,3}(?<f>`{3,}|~{3,})")? // null) as $open
      | if $open != null then .fence = $open.f
        elif ($line | test("^<!-- review-verdict: (fixed|deferred|declined) ")) then .found = true
        else . end
    else
      (.fence) as $f
      | ($line | capture("^ {0,3}(?<f>`+|~+)[ \t]*$")? // null) as $close
      | if $close != null
           and ($close.f[0:1] == $f[0:1])
           and (($close.f | length) >= ($f | length))
        then .fence = null
        else . end
    end
  ) | .found;

(. // []) as $c
| ([ $c[]
     | select((.user.login // "") as $l | any(review_bot_logins[]; . == $l))
     | .id ] ) as $bot_ids
| [ $c[]
    | select(.in_reply_to_id != null)
    | select(.in_reply_to_id as $r | any($bot_ids[]; . == $r))
    | select((.user.type // "") == "User")
    | select(((.user.login // "") | endswith("[bot]")) | not)
    | select((.body | has_verdict_marker) | not)
  ]
| length
