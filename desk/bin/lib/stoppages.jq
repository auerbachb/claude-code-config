# desk/bin/lib/stoppages.jq — groups stoppage rows by cause for `stoppage list`
# (issue #2292). Input: one JSON array of rows, each with at least `cause`,
# `corrected_cause` (or null) and `idle_seconds` (or null while the work is
# still stopped). Args: $from, $to (the range, for the heading).
#
# The cause counted is the operator's correction when there is one. An entry
# whose work has not resumed yet counts as a stoppage but adds no idle time and
# is reported as open, so a total is never inflated by a guess.
(map(. + {eff: (.corrected_cause // .cause)})) as $rows
| ($rows | group_by(.eff)
   | map({cause: .[0].eff,
          count: length,
          open: (map(select(.idle_seconds == null)) | length),
          idle_seconds: (map(.idle_seconds // 0) | add)})
   | sort_by([-.idle_seconds, -.count, .cause])) as $causes
| {from: $from, to: $to,
   total: ($rows | length),
   open: ($rows | map(select(.idle_seconds == null)) | length),
   idle_seconds: ($rows | map(.idle_seconds // 0) | add // 0),
   causes: $causes}
