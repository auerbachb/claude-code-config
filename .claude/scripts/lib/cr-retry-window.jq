# cr-retry-window.jq — the one parser for free-reviewer "next review available in N"
# retry windows (issues #1199, #1364, #2256). *(library — loaded with `jq -L <lib> 'include "cr-retry-window"; …'`)*
#
# Consumers: escalate-review.sh (CodeRabbit retry-window grace), no-review-override.sh
# and review-availability.sh (the account-wide availability record). Do not copy these
# defs into another script: a second banner regex drifts silently (#1364).
#
# Wording drifts. Key on the stable anchors, never the whole sentence:
#   `next` … `review available in` … number + unit, case-insensitive, optional colon.
# The allowance is bounded: 0-2 words before `review` (an adjective slot), and the
# literal copula `will be` after it (CodeRabbit's future-tense form, PR #554). The
# copula is a literal, not a generic bridge, because the adaptive-limits notice is
# ordinary prose elsewhere. Markdown emphasis is stripped first. Rationale and the
# full observed-wording table: .claude/reference/cr-rate-limits.md.

# Matched sentence fragment (lowercased, emphasis stripped) plus the parsed number and
# unit. Collected into an array first: `capture` emits an empty generator on no-match,
# and binding that directly would silently drop the enclosing object.
def cr_retry_capture:
  ascii_downcase | gsub("\\*"; "")
  | [ capture("(?<s>\\bnext(?:\\s+\\w+){0,2}\\s+review\\s+(?:will\\s+be\\s+)?available\\s+in:?\\s*(?<n>[0-9]+)\\s*(?<unit>second|minute|hour))") ]
  | first;

# Window in seconds, or 0 when the text carries no readable window.
def cr_retry_window_seconds:
  (cr_retry_capture) as $m
  | if $m == null then 0
    else ($m.n | tonumber) * (if $m.unit == "hour" then 3600 elif $m.unit == "minute" then 60 else 1 end)
    end;

# ISO-8601 UTC timestamp (GitHub's `Z` and `+00:00` shapes, optional fractional seconds)
# to epoch seconds; null when malformed. A malformed value must never read as "now".
def cr_iso_epoch:
  if type != "string" then null
  else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $s
    | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) then ($s | fromdateiso8601) else null end
  end;
