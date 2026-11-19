include "check-run-conclusions";

$req | map(
  . as $c
  | ($apps[$c] // null)                                          as $app
  | [ $runs.check_runs[]? | select(._workflow_inventory != true) | select((.name // "") == $c) ]        as $named
  | (if $app == null then $named
     else [ $named[] | select((.app.id // null) == $app) ] end)  as $r
  | ( [ $statuses[]? | select((.context // "") == $c) ] | first ) as $s
  | ($s != null and ($s.state // "") != "success") as $status_blocks
  | (if ($app != null and ($r | length) == 0) then
       # Legacy statuses expose no app identity and cannot prove an app pin.
       {context: $c, state: (if ($named | length) > 0 or $s != null then "wrong_app" else "absent" end), satisfied: false}
     elif (($r | length) == 0 and $s == null and ($named | length) > 0) then
       {context: $c, state: "wrong_app", satisfied: false}
     elif (($r | length) == 0 and $s == null) then
       {context: $c, state: "absent", satisfied: false}
     elif any($r[]; completed_check | not) then
       {context: $c,
        state: ([ $r[] | select(completed_check | not)
                  | ((.status // "") | if . == "" then "incomplete" else . end) ] | first),
        satisfied: false}
     elif any($r[]; .conclusion | required_check_passes | not) then
       [$r[] | select(.conclusion | required_check_passes | not)] as $bad
       | {context: $c,
          state: ($bad[0].conclusion // "none" | if . == "" then "none" else . end),
          satisfied: false}
       | if ($bad | length) == 1 and $bad[0].conclusion == "cancelled"
            and ($status_blocks | not) and $bad[0].app.slug == "github-actions"
            and ($bad[0].id | type == "number" and . > 0 and floor == .)
         then . + {cancelled_check: ($bad[0] | {id, name})}
         else . end
     elif $status_blocks then
       {context: $c,
        state: (($s.state // "") | if . == "" then "unknown" else . end),
        satisfied: false}
     else
       {context: $c, state: "passing", satisfied: true}
     end))
