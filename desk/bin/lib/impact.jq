# desk/bin/lib/impact.jq — the derived-impact rule (issue #1760), in one
# place: `human-queue.sh impact` derives with it and the offline tests run it
# directly. Loaded with `jq -L desk/bin/lib 'include "impact"; …'`.
#
# THE RULE (thresholds from desk/policy.json)
#   critical-path  the issue's open dependents, counted down every chain, are
#                  at least critical_path_min_dependents; or /pm's backlog
#                  ranking is fresh (under a day old) and ranks the issue at
#                  critical_path_rank_top_n or better
#   medium         otherwise, at least one open issue depends on it, or the
#                  asking agent is parked on the item (it waits for the answer)
#   low            otherwise
#   Declared impact is never an input. A rank that is unknown (no ranking, or
#   one a day old or more) leaves the dependents and the parked flag to decide.

def impact_plural($n; $one; $many): "\($n) " + (if $n == 1 then $one else $many end);

# impact_derive($top_n; $min_deps): input {rank_status ("fresh" or not),
# rank (number or null), dependents (the transitive open-dependent count)}.
# Output: {impact, impact_parked, basis, basis_parked}: the value for an item
# whose agent is not parked and for one that is, and the inputs in words. The
# basis is built from numbers and fixed words only.
def impact_derive($top_n; $min_deps):
  (.rank_status == "fresh" and (.rank | type) == "number") as $ranked
  | (.dependents >= $min_deps or ($ranked and .rank <= $top_n)) as $critical
  | (if $critical then "critical-path" elif .dependents >= 1 then "medium" else "low" end) as $base
  | ([ impact_plural(.dependents; "open dependent"; "open dependents"),
       (if .rank_status != "fresh" then "backlog rank unknown"
        elif $ranked then "backlog rank \(.rank)"
        else "not in the backlog ranking" end) ] | join(", ")) as $basis
  | { impact: $base,
      impact_parked: (if $base == "low" then "medium" else $base end),
      basis: $basis,
      basis_parked: ($basis + ", agent parked") };

# impact_reports($rank; $deps; $top_n; $min_deps): one report per issue in
# $deps (issue-deps.sh dependents' object), its rank read from $rank
# (pm-rank-cache.sh read's object; anything else is an unknown rank).
def impact_reports($rank; $deps; $top_n; $min_deps):
  (if ($rank | type) == "object" and $rank.status == "fresh" then "fresh" else "unknown" end) as $status
  | ([ (if ($rank | type) == "object" then ($rank.issues // []) else [] end)[]
       | select(type == "object" and (.issue | type) == "number")
       | {key: (.issue | tostring), value: .} ] | from_entries) as $ranks
  | [ ($deps.issues // [])[]
      | ($ranks[.issue | tostring] // {}) as $r
      | { issue,
          rank_status: $status,
          rank_reason: (if $status == "fresh" then null
                        elif ($rank | type) == "object" then ($rank.reason // "unknown") else "unknown" end),
          rank: (if $status == "fresh" then $r.rank else null end),
          tier: (if $status == "fresh" then $r.tier else null end),
          dependents: .count, direct, transitive, cycle }
      | . + impact_derive($top_n; $min_deps) ];

# impact_payload: the reports as the store's write payload, numbers and the
# rule's fixed words only.
def impact_payload: map({issue, impact, impact_parked, basis, basis_parked});
