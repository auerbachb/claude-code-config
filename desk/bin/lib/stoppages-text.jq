# desk/bin/lib/stoppages-text.jq — renders the object stoppages.jq produces as
# the text `stoppage list` prints. Same duration helper as stoppages.jq.
def dur:
  . as $s
  | ($s / 3600 | floor) as $h
  | (($s % 3600) / 60 | floor) as $m
  | if $h > 0 then "\($h)h \($m | tostring | if length < 2 then "0" + . else . end)m"
    else "\($m)m" end;
def pad($n): . + (" " * ([$n - length, 1] | max));
"\(.from) to \(.to) · \(.total) stoppage\(if .total == 1 then "" else "s" end) · \(.idle_seconds | dur) idle"
+ (if .open > 0 then " · \(.open) still stopped, not totalled" else "" end),
(.causes[] | "  \(.cause | pad(20)) \(.count) · \(.idle_seconds | dur)")
