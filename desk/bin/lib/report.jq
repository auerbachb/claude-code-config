# desk/bin/lib/report.jq — the weekly attention report as text (issue #1771).
# Input: `human-queue.sh report --json`'s object, models resolved. Output:
# one page of Markdown: a bold title, the five measures as a numbered list,
# and one small table of the threads the operator tagged. Loaded with
# `jq -L desk/bin/lib 'include "report"; report_text'`.

# report_dur: whole minutes as 45m, 2h, 1h 25m, 3d, 2d 4h.
def report_dur:
  (. | round) as $t
  | if $t < 60 then "\($t)m"
    elif $t < 1440 then
      "\(($t / 60) | floor)h" + (if ($t % 60) > 0 then " \($t % 60)m" else "" end)
    else
      (($t % 1440) / 60 | floor) as $h
      | "\(($t / 1440) | floor)d" + (if $h > 0 then " \($h)h" else "" end)
    end;

def report_plural($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";

# A table cell: never a character that would end the cell or the row.
def report_cell: tostring | gsub("[|`\\\\\r\n]"; "?");

# The thread column: the session id's first eight characters.
def report_thread:
  if . == null then "(no thread)" else (.[0:8] | report_cell) end;

def report_text:
  . as $r
  | ($r.threads | length) as $nthreads
  | [
      "**Attention report · week of \($r.week.start) to \($r.week.end)\(if $r.today < $r.week.end then " (to date)" else "" end)**",
      "",
      "1. Minutes spent answering: "
        + (if $r.minutes.sittings == 0 then "0 (no desk activity)"
           else "\($r.minutes.total) min over \(report_plural($r.minutes.sittings; "sitting"; "sittings"))" end),
      "2. Items per day: "
        + (if $r.handled.desk_days == 0 then "none handled"
           else "\($r.handled.per_desk_day) per desk day (\($r.handled.total) handled on \(report_plural($r.handled.desk_days; "day"; "days")))" end)
        + (if ($r.days | length) > 0
           then " · " + ([$r.days[] | "\(.dow) \(.handled)"] | join(" · "))
           else "" end),
      "3. Median age of an open Decision: "
        + (if $r.open_age.decisions == 0 then "none was open this week"
           else "\($r.open_age.median_minutes | report_dur) (\(report_plural($r.open_age.decisions; "Decision"; "Decisions")) open during the week, \($r.open_age.still_open) still open at its end)" end),
      "4. Interrupts tagged not important: \($r.not_important.tagged) (of \(report_plural($r.not_important.shown; "Decision"; "Decisions")) shown)",
      "5. Questions tagged should have defaulted: \($r.should_have_defaulted.tagged)"
        + (if $nthreads > 0 then ", by thread and model:" else "" end),
      ""
    ]
    + (if $nthreads == 0 then ["No thread was tagged this week."]
       else
         [ "| Thread | Model | Asked | Should have defaulted | Not important | Good interrupt |",
           "|--------|-------|------:|----------------------:|--------------:|---------------:|" ]
         + [ $r.threads[0:10][]
             | "| \(.session | report_thread) | \(if .session == null then "–" else (.model // "unknown" | report_cell) end) | \(if .asked == null then "–" else .asked end) | \(.should_have_defaulted) | \(.not_important) | \(.good_interrupt) |" ]
         + (if $nthreads > 10 then ["", "\($nthreads - 10) more \(if $nthreads - 10 == 1 then "thread" else "threads" end): `report --json` lists every one."] else [] end)
       end)
  | join("\n");
