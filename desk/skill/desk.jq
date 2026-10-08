# desk/skill/desk.jq — the /desk skill's deterministic item logic (issues
# #1779, #1780, #1783, #1784): which Decisions fit a menu, how the simple ones chunk
# into sets and the long-form ones group into multipart items, the exact text
# of a long-form card and a discussion card, and which replies are feedback
# tags rather than answers. One file, so the menus and the long-form view
# share one predicate, and the tests run these functions themselves rather
# than copies of them.
#
# Use:    jq -L "$DESK/skill" 'include "desk"; <function>'
# Input:  the CLI's item JSON — `list --json` arrays, `get --json` objects.
# Tests:  desk/tests/longform-offline.test.sh (fixtures),
#         desk/tests/longform.test.sh (live, throwaway schema);
#         the Reviews view (#1782): desk/tests/reviews-view-offline.test.sh
#         (fixtures) and desk/tests/reviews-view.test.sh (live); sets and
#         feedback tags (#1783): desk/tests/interrupts-offline.test.sh
#         (fixtures) and desk/tests/interrupts.test.sh (live); the day plan
#         and the end-of-day sweep (#1784): desk/tests/plan-offline.test.sh
#         (fixtures) and desk/tests/plan.test.sh (live); the to-do layer
#         (#1769): desk/tests/todo-offline.test.sh (fixtures) and
#         desk/tests/todo.test.sh (live).

# ---------------------------------------------------------------- classify

# long_cost: the declared cost is in hours, days, or weeks ("2h", "1h30",
# "2hrs", "an hour", "half a day", "a week"): more than minutes. A unit
# counts after a number or as a whole word, so "Thursday" and "holiday" do
# not.
def long_cost:
  (.cost // "")
  | test("[0-9] *(h|hrs?|hours?|days?|wks?|weeks?)([0-9]|\\b)|\\b(hrs?|hours?|days?|wks?|weeks?)\\b"; "i");

# menu_shaped: fits one question of a menu — 2 to 4 options (the question
# tool's limits) and a cost in minutes, or none declared.
def menu_shaped:
  ((.options // []) | length) as $n | $n >= 2 and $n <= 4 and (long_cost | not);

# desk_split($ids): splits a `list --json` array into what the desk shows as
# menus and what it shows as long-form text prompts. $ids is a tick event's
# space-separated ids, or "" for every item. Only open Decisions count: an id
# the list no longer has was answered or closed meanwhile and drops out.
#
#   {"simple": ["D-43", "D-44"], "longform": [["D-45"], ["D-47", "D-48"]]}
#
# simple keeps the list's order (parked, then impact, then age). longform
# holds one array per multipart group — the long-form Decisions that share a
# repo, a key, and a return address: one thread asking about one PR or issue
# (a multi-question ask is stored as one Decision per question). Parts keep
# the list's order inside a group; groups are ordered by their first part. A
# group of one is a single long-form Decision.
#
# With $ids, a named long-form Decision brings its whole group: every open
# long-form part sharing its repo, key, and return address comes along, named
# or not. The capture hook adds a multi-question ask one Decision at a time,
# so a tick can land between two parts and report them in different events;
# without this the later part would be shown alone as part 1 of 1.
def group_key: [.repo, .key, .session_id];

def desk_split($ids):
  ($ids | split(" ") | map(select(. != ""))) as $want
  | [ to_entries[]
      | select(.value.kind == "decision" and .value.status == "open")
      | {n: .key, item: .value, named: (.value.id as $i | any($want[]; . == $i))} ] as $open
  | ([ $open[] | select(.named and (.item | menu_shaped | not)) | .item | group_key ]) as $groups
  | [ $open[]
      | select(($want | length) == 0 or .named
               or ((.item | menu_shaped | not)
                   and ((.item | group_key) as $g | any($groups[]; . == $g)))) ] as $rows
  | { simple: [ $rows[] | select(.item | menu_shaped) | .item.id ],
      longform: ( [ $rows[]
                    | select(.item | menu_shaped | not)
                    | {n, id: .item.id, g: (.item | group_key)} ]
                  | group_by(.g) | map(sort_by(.n)) | sort_by(.[0].n)
                  | map(map(.id)) ) };

# desk_sets($size): an array of ids (desk_split's simple ones) chunked into
# the sets the desk opens one at a time, in order: ["D-1", …, "D-5"] with
# size 4 is [["D-1", "D-2", "D-3", "D-4"], ["D-5"]]. $size is the policy's
# set_size, a whole number from 1 to 4 (four questions is the menu tool's
# limit); anything else is 4. [] for no ids.
def desk_sets($size):
  (if ($size | type) == "number" and ($size | floor) == $size and $size >= 1 and $size <= 4
   then $size else 4 end) as $s
  | . as $ids
  | [ range(0; $ids | length; $s) as $i | $ids[$i:$i + $s] ];

# desk_batch($ids; $size): desk_split($ids) with its simple ids also chunked
# into sets (issue #1783), so three new Decisions are one set and a fifth
# opens a second one when the size is four:
#
#   {"simple": ["D-43", "D-44"], "longform": [["D-45"]], "sets": [["D-43", "D-44"]]}
def desk_batch($ids; $size):
  desk_split($ids) | . + {sets: (.simple | desk_sets($size))};

# ---------------------------------------------------------- feedback (#1783)

# feedback_tag: one tag phrase as typed ("Not important.", "should have
# defaulted", "good-interrupt") as the stored tag, else null. Any case, words
# separated by spaces or hyphens, an optional trailing period.
def feedback_tag:
  ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "") | sub("\\.$"; "")
  | gsub("[\\s-]+"; " ")
  | if . == "not important" then "not-important"
    elif . == "should have defaulted" then "should-have-defaulted"
    elif . == "good interrupt" then "good-interrupt"
    else null end;

# desk_feedback: the operator's whole message (a string, as `jq -Rs` reads
# it) as feedback tags, [{"ref": "2", "tag": "not-important"}, {"ref":
# "D-43", "tag": "good-interrupt"}], when every pair in it is `<n|D-id>: not
# important | should have defaulted | good interrupt`, pairs separated by
# commas, semicolons, or line breaks. Anything else is null: the message is
# not feedback, so it stays an answer or a remark. ref is the item's number
# in the latest set (1 to 99) or its id, uppercased. A Review's id (R-<n>) is
# deliberately not a ref: the tags tune interrupts, and a Review never
# interrupts (it waits in the Reviews view, with no asking thread and no
# default to take). The CLI's `feedback` still takes any item's id.
def desk_feedback:
  [ split("\n")[] | split(";")[] | split(",")[]
    | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "") ] as $pairs
  | if ($pairs | length) == 0 then null
    else
      [ $pairs[]
        | (capture("^(?<ref>[1-9][0-9]?|[Dd]-[1-9][0-9]*)\\s*:\\s*(?<tag>.*)$") // null)
        | if . == null then null
          else (.tag | feedback_tag) as $t
          | if $t == null then null else {ref: (.ref | ascii_upcase), tag: $t} end
          end ]
      | if any(.[]; . == null) then null else . end
    end;

# ------------------------------------------------------------------ render

def letter($i): [65 + $i] | implode;

# The capture hook stores the asking thread's own option label, which often
# ends in "(Recommended)"; the desk marks the default itself, exactly once.
def bare_label: sub("\\s*\\(Recommended\\)\\s*$"; "");

# utc: a timestamptz as the CLI's JSON carries it ("2026-10-05T18:00:00+00:00";
# fractions of a second and any offset allowed) as "2026-10-05 18:00 UTC".
# Anything else is returned unchanged.
def utc:
  if type != "string" then .
  else
    . as $raw
    | ([capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}(:[0-9]{2})?)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}(:?[0-9]{2})?)$")] | .[0]) as $m
    | if $m == null then $raw
      else
        ($m.z
         | if . == "Z" then 0
           else ((.[1:3] | tonumber) * 3600
                 + (.[3:] | ltrimstr(":") | if . == "" then 0 else tonumber * 60 end))
                * (if startswith("-") then -1 else 1 end)
           end) as $off
        | ($m.t | if length == 5 then . + ":00" else . end) as $t
        | (($m.d + "T" + $t + "Z") | fromdateiso8601) - $off
        | strftime("%Y-%m-%d %H:%M UTC")
      end
  end;

# item_link: the item's PR or issue on GitHub, derived from repo and key (the
# store keeps no other link): {"label": "PR #318", "url": "https://…"}. A
# `branch:` key links to the branch. null for a `local/…` repo, a `session:`
# key, or a key the capture hook shortened (it ends in `~` and 12 hex digits,
# so it no longer names the branch).
def item_link:
  (.repo // "") as $r | (.key // "") as $k
  | if ($r | startswith("local/")) or ($r | test("^[^/\\s]+/[^/\\s]+$") | not)
       or ($k | test("~[0-9a-f]{12}$")) then null
    elif ($k | test("^pr-[1-9][0-9]*$")) then
      {label: ("PR #" + $k[3:]), url: ("https://github.com/" + $r + "/pull/" + $k[3:])}
    elif ($k | test("^issue-[1-9][0-9]*$")) then
      {label: ("Issue #" + $k[6:]), url: ("https://github.com/" + $r + "/issues/" + $k[6:])}
    elif ($k | startswith("branch:")) and ($k | length) > 7 then
      {label: ("branch " + $k[7:]),
       url: ("https://github.com/" + $r + "/tree/" + ($k[7:] | split("/") | map(@uri) | join("/")))}
    else null
    end;

def context_lines: (.context // []) | to_entries[] | "\(.key + 1). \(.value)";

def options_line:
  if ((.options // []) | length) == 0 then empty
  else .default_option as $d
    | "Options: " + ([ .options | to_entries[]
                       | letter(.key) + ". " + (.value | bare_label)
                         + (if .value == $d then " (Recommended)" else "" end) ]
                     | join(" · "))
  end;

def default_line:
  if .default_option == null then empty
  else ( .default_option as $d
         | [ (.options // []) | to_entries[] | select(.value == $d) | .key ] | .[0] ) as $at
    | "Default: " + (if $at == null then "" else letter($at) + ". " end) + (.default_option | bare_label)
      + (if .default_at == null then ""
         else " — the thread takes it at " + (.default_at | utc) + " if unanswered" end)
  end;

def facts_line:
  [ (.impact_declared // empty | "Impact: " + .),
    (.cost // empty | "Cost: " + .),
    (.focus // empty | "Focus: " + .),
    (if .parked then "Parked: the thread waits for this answer" else empty end) ]
  | if length == 0 then empty else join(" · ") end;

def link_line: item_link | if . == null then empty else "Link: " + .label + " — " + .url end;

def return_line:
  if .session_id == null then
    "Answer goes to: the store only (no return address); the next thread on this work reads it there"
  else
    "Answer goes to: the asking thread (session "
    + (.session_id | if length > 12 then .[0:8] + "…" else . end)
    + "), woken with `human-queue: " + .id + " answered`; if that thread has ended, the next one on this work reads it from the store"
  end;

# The card's body: the question in bold, the numbered context, the options
# with the default marked, the default and when it is taken, impact and cost,
# the link, and where the answer goes.
def item_lines:
  "**" + .question + "**", context_lines, options_line, default_line, facts_line, link_line, return_line;

# quote: an array of lines (each may hold line breaks) as one blockquote. The
# card quotes the asking thread's question. A blockquote is also what #1778's
# prose-question nudge reads as a quotation, so the desk's own prompt is never
# mistaken for a question the desk asks in prose.
def quote:
  [ .[] | split("\n")[] ] | map(if . == "" then ">" else "> " + . end) | join("\n");

# render_longform($k; $m): the text prompt for one long-form Decision (a `get
# --json` object), part $k of $m of its multipart group ($m = 1: a single
# long-form Decision). The desk prints it as is, never as a menu.
def render_longform($k; $m):
  ([ ([ "**" + .id + "**",
        (if $m > 1 then "part \($k) of \($m)" else "long-form" end),
        .repo, .key ] | join(" · ")),
     item_lines ] | quote)
  + "\n\n"
  + (if ((.options // []) | length) > 0
     then "Reply with a letter to pick an option, or write your own answer."
     else "Write your answer." end)
  + " Your next message is stored as " + .id + "'s answer, word for word."
  + " `skip` leaves it open; `discuss` talks it through first.";

# longform_prompt($k; $m): render_longform for an item that is still open; for
# one answered or closed since it was queued (another desk, a typed reply), a
# one-line notice instead, so the desk moves on rather than asking again.
def longform_prompt($k; $m):
  if .status == "open" then render_longform($k; $m)
  else "\(.id) is \(.status) now, so it is skipped."
  end;

# discuss_card: what `discuss` loads for one item (a `get --json` object): the
# header with its status and when it was asked, the card's body, and the
# answer so far, as one blockquote.
def discuss_card:
  [ ([ "Discussing **" + .id + "**", .status, .repo, .key,
       (.created_at // empty | "asked " + utc) ] | join(" · ")),
    item_lines,
    (.answer // empty | "Answer so far: " + .) ]
  | quote;

# ----------------------------------------------------------- reviews (#1782)
#
# The Reviews view: `list --kind reviews --unreviewed --json` is
# {count, level2_lines, today, items}, each item with synced_on (the
# America/New_York day it was synced) and, once the desk has written it,
# summary_l1 (its one cached line).

# review_label: "PR #101" or "Issue #202" from a Review's key; the key itself
# when it names neither.
def review_label: (item_link | if . == null then null else .label end) // .key;

# short_repo($all): the repository without its owner, unless another
# repository in $all (an array of owner/name strings) has the same name.
def short_repo($all):
  . as $r | ($r | split("/") | .[1] // $r) as $n
  | if ([ $all[] | select((split("/") | .[1] // "" | ascii_downcase) == ($n | ascii_downcase))
          | ascii_downcase ] | unique | length) > 1
    then $r else $n end;

# day_epoch: a YYYY-MM-DD day as seconds (UTC midnight); null when malformed.
def day_epoch:
  if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  then (. + "T00:00:00Z" | fromdateiso8601) else null end;

# day_label($today): "Today", "Yesterday", or "Mon Oct 5" for a day.
def day_label($today):
  day_epoch as $d | ($today | day_epoch) as $t
  | if $d == null then "Undated"
    elif $d == $t then "Today"
    elif $t != null and $d == $t - 86400 then "Yesterday"
    else $d | strftime("%a %b %d") | sub(" 0(?<n>[1-9])$"; " \(.n)")
    end;

# review_line: one item at level 1. Until the desk caches its line, the title
# stands in, marked so it is never mistaken for a summary.
def review_line:
  .id + " · " + review_label + " · "
  + (if (.summary_l1 // "") != "" then .summary_l1
     else .question + " (title; not summarized yet)" end);

# reviews_missing_l1: the unreviewed items with no level-1 line yet, one per
# output line: id, repo, and key separated by U+001F (none of the three is
# ever empty, and none can hold that character).
def reviews_missing_l1:
  .items[] | select((.summary_l1 // "") == "") | [.id, .repo, .key] | join("\u001f");

# reviews_view: the whole view. A header with the backlog and its reading
# estimate; then one group per day and repository, newest day first and
# repositories by name inside a day, each `<day> · <repo> (<n>)` followed by
# its items oldest first; then one line naming what to type next.
def reviews_view:
  if ((.items // []) | length) == 0 then "No unreviewed Reviews."
  else
    (.today // null) as $today
    | ([ .items[].repo ] | unique) as $repos
    | ([ .items
         | group_by([.synced_on, (.repo | ascii_downcase)])[]
         | { day: .[0].synced_on, name: (.[0].repo | short_repo($repos)),
             items: sort_by([(.id | length), .id]) } ]
       | sort_by([ -((.day | day_epoch) // 0), (.name | ascii_downcase) ])) as $groups
    | ([ "Reviews · \(.count) unreviewed · ~\(.level2_lines) lines at level 2" ]
       + [ $groups[]
           | "",
             "\(.day | day_label($today)) · \(.name) (\(.items | length))",
             (.items[] | review_line) ]
       + [ "", "Next: open R-<n> · diff R-<n> [path] · reviewed R-<n> · reviewed all today · flag R-<n> \"…\"" ])
      | join("\n")
  end;

# review_header: the first lines of `open` and `diff` (a `get --json`
# object): the id, PR or issue, repository, when it merged or was filed, and
# the status once it is no longer unreviewed; then the link.
def review_header:
  ([ .id, review_label, .repo, ((.context // [])[1] // empty),
     (if .status != "open" then .status else empty end) ] | join(" · "))
  + (item_link | if . == null then "" else "\n" + .url end);

# --------------------------------------------------------- day plan (#1784)
#
# The plan dialogue (plan.md). The operator's sentence is parsed here, by one
# grammar, so the desk never guesses a plan out of prose; the proposal, its
# card, and the record `plan set` stores are built here too, so a test runs
# the same code the desk does. Times: the CLI's ISO 8601 UTC strings in,
# America/New_York clock times out, through strflocaltime — run these with
# TZ=America/New_York in the environment (the skill's blocks do).

# plan_num: a number as typed ("30", "four", "an", "half an") as a number;
# null when it is none of them.
def plan_num:
  ascii_downcase | gsub("\\s+"; " ")
  | if test("^[0-9]+(\\.[0-9]+)?$") then tonumber
    else {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
          "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
          "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
          "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
          "half a": 0.5, "half an": 0.5}[.]
    end;

def plan_num_re:
  "(?<num>[0-9]+(?:\\.[0-9]+)?|half an?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty-five|forty|fifty|sixty|ninety)";
def plan_unit_re: "(?<unit>minutes?|mins?|m|hours?|hrs?|h)\\b(?<half>\\s+and a half)?";

# plan_minutes: a {num, unit, half} capture as whole minutes; null when the
# number is not one.
def plan_minutes:
  (.num | plan_num) as $v
  | if $v == null then null
    else (if (.unit | startswith("h")) then 60 else 1 end) as $m
      | ($v * $m + (if .half != null then (if $m == 60 then 30 else 0 end) else 0 end)) | round
      | if . >= 1 then . else null end
    end;

def plan_trim: sub("^\\s+"; "") | sub("\\s+$"; "");

# plan_cap($m; $name): one named capture of a match object, or null.
def plan_cap($m; $name):
  if $m == null then null else ($m.captures | map(select(.name == $name)) | .[0].string) end;

def plan_mins($m):
  if $m == null then null
  else {num: plan_cap($m; "num"), unit: plan_cap($m; "unit"), half: plan_cap($m; "half")} | plan_minutes end;

# plan_fields: the plan's fields in one piece of text (the part after the
# trigger, or a reply while a plan is being agreed):
#   {item, pace_min, chunk, count, until, for_min}
# pace is `<n> <unit> a|per|each|every <chunk>`, `each <chunk> is|takes
# <n> <unit>`, or `<n> <unit> each`; an
# extent is `<n> <chunk>s` (`<n> of them`), `until|till|to <time>`, or `for
# <n> <unit>`, and the item is what comes before the first comma, semicolon,
# colon, dash, or field. A field it does not find is null.
def plan_fields:
  (gsub("[’‘]"; "'") | plan_trim) as $t
  | ($t | ascii_downcase) as $l
  | ([ $l | match("(?:about |around |roughly |~)?" + plan_num_re + "\\s*" + plan_unit_re
                  + "\\s+(?:for\\s+)?(?:a|an|per|each|every)\\s+(?<chunk>[a-z][a-z-]*)"; "g") ] | .[0]) as $pm
  | ([ $l | match("(?:about |around |roughly |~)?" + plan_num_re + "\\s*" + plan_unit_re + "\\s+each\\b"; "g") ]
     | .[0]) as $em
  | ([ $l | match("\\beach\\s+(?<chunk>[a-z][a-z-]*)\\s+(?:is|takes|will take|should take)\\s+(?:about |around |roughly |~)?"
                  + plan_num_re + "\\s*" + plan_unit_re; "g") ] | .[0]) as $xm
  | ([ $l | match("\\bfor\\s+(?:about |around |roughly )?" + plan_num_re + "\\s*" + plan_unit_re; "g") ]
     | .[0]) as $fm
  | ([ $l | match("\\b(?:until|till|til|to|through)\\s+(?<t>noon|midday|lunch|[0-9]{1,2}(?::[0-5][0-9])?(?:\\s?[ap]\\.?m\\.?)?)(?![0-9:])"; "g") ]
     | .[0]) as $um
  | ([ $l | match("\\b(?<num>[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\s+(?:more\\s+)?(?:(?<noun>[a-z][a-z-]*?)s\\b|of them\\b)"; "g") ]
     | map(select((plan_cap(.; "noun") // "") | test("^(minute|min|hour|hr|h|m|second|sec)$") | not))
     | .[0]) as $cm
  | ([ ($pm, $em, $xm, $fm, $um, $cm | select(. != null) | .offset) ]
     + [ $l | match("\\s[—–]\\s|\\s-\\s|[,;:]"; "g") | .offset ] | min) as $cut
  | ($t[0:($cut // ($t | length))] | plan_trim
     | sub("^(?i:(?:ok(?:ay)?|so|right|actually|well|then|and|make it|make that|change it to|change to|let's say|let's do|say|do)\\b[, ]*)+"; "")
     | sub("(?i:\\s+(?:today|tonight|this morning|this afternoon|now|first|next|for now|then))+$"; "")
     | plan_trim
     | if . == "" or test("^(?i:it|that|this|them|one|ones)$") or (test("[A-Za-z]") | not) then null else . end) as $item
  | { item: $item,
      pace_min: (plan_mins($pm) // plan_mins($xm) // plan_mins($em)),
      chunk: (plan_cap($pm; "chunk") // plan_cap($xm; "chunk") // plan_cap($cm; "noun")),
      count: (if $cm == null then null else (plan_cap($cm; "num") | plan_num) end),
      until: (if $um == null then null else plan_cap($um; "t") | gsub("[.\\s]"; "") end),
      for_min: plan_mins($fm) };

# The phrases that start a new plan, before what it is for.
def plan_work_re:
  "^(?i:(?:(?:ok(?:ay)?|so|right|today|this morning|this afternoon)[, ]+)?(?:i need to|i have to|i must|i want to|i'd like to|i would like to|i'll|i will|i'm going to|i am going to|i'm|i am|let me|let's|we need to|time to)\\s+work(?:ing)?\\s+on\\s+|(?:today|tonight|this morning|this afternoon|the morning|the afternoon)\\s+is\\s+for\\s+)";

# desk_plan_parse($pending): the operator's whole message (a string, as
# `jq -Rs` reads it) as
#   {"trigger": "plan"|"show"|"off"|"work"|"revise"|null,
#    "confirm": bool, "cancel": bool, "fields": {...plan_fields...}}
# The triggers, any case, as the whole message (a final period is fine):
#   plan                      start a plan: the desk asks what and how fast
#   plan?                     show today's plan
#   plan off, plan clear, no plan, drop the plan
#                             clear it
#   plan: <text>              revise today's plan (or start one) with <text>
#   I need to work on <text>  (also: I have to / want to / will / am going to
#                             work on, I'm working on, let me / let's work on,
#                             today / this morning / this afternoon is for)
#                             a new plan for <text>
# With no trigger, fields are read only while a plan is being agreed: a
# reply such as `4 sections` or `until 12:30`. $pending is false (no plan is
# being agreed), true (one is, and its item is known: a reply never renames
# it, so a remark is not read as an item), or "item" (the desk asked what the
# plan is for: the reply's leading words are the item). A reply with no field
# in it has every field null: it is not about the plan. confirm (`yes`, `ok`,
# `sounds right`, ...) and cancel (`no`, `cancel`, `never mind`, ...) are the
# whole message.
def desk_plan_parse($pending):
  (gsub("[’‘]"; "'") | plan_trim | sub("[.!]+$"; "") | plan_trim) as $m
  | ($m | ascii_downcase | gsub("\\s+"; " ")) as $l
  | ("" | plan_fields) as $none
  | {confirm: ($l | test("^(yes|y|yep|yeah|yup|ok|okay|sure|sounds (right|good)|confirm(ed)?|go|go ahead|do it|start|perfect|great|looks good|that works)$")),
     cancel: ($l | test("^(no|nope|cancel|never ?mind|drop it|scrap it|forget it|not now)$"))}
  | if $l == "plan" then . + {trigger: "plan", fields: $none}
    elif $l == "plan?" then . + {trigger: "show", fields: $none}
    elif ($l | test("^(plan (off|clear|cancel|drop)|no plan|drop the plan|clear the plan|cancel the plan)$"))
      then . + {trigger: "off", fields: $none}
    elif ($m | test("^(?i:plan)\\s*:")) then
      . + {trigger: "revise", fields: ($m | sub("^(?i:plan)\\s*:\\s*"; "") | plan_fields)}
    elif ($m | test(plan_work_re + "\\S")) then
      . + {trigger: "work", fields: ($m | sub(plan_work_re; "") | plan_fields)}
    elif $pending == "item" and ((.confirm or .cancel) | not) then . + {trigger: null, fields: ($m | plan_fields)}
    elif $pending == true and ((.confirm or .cancel) | not) then . + {trigger: null, fields: ($m | plan_fields | .item = null)}
    else . + {trigger: null, fields: $none}
    end;

# desk_plan_merge($new): the inputs agreed so far (., {} at first) with the
# fields of one more sentence over them: a field it names replaces the old
# one; an extent (count, until, or for) replaces the whole old extent, and
# `end` (the extent as an absolute time, set by desk_plan_propose) goes with
# it. `count_given` marks a count named in this sentence, which a revision
# reads as the chunks still to do.
def desk_plan_merge($new):
  (. // {}) as $o
  | ($new.count != null or $new.until != null or $new.for_min != null) as $extent
  | { item: ($new.item // $o.item),
      pace_min: ($new.pace_min // $o.pace_min),
      chunk: ($new.chunk // $o.chunk),
      count: (if $extent then $new.count else $o.count end),
      until: (if $extent then $new.until else $o.until end),
      for_min: (if $extent then $new.for_min else $o.for_min end),
      end: (if $extent then null else $o.end end),
      count_given: ($new.count != null) };

# Epoch seconds and the desk's clock.
def plan_epoch: if type == "number" then . else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;
def plan_iso: floor | todate;
def plan_hm: floor | strflocaltime("%H:%M");
def plan_ceil_min: (. / 60 | ceil) * 60;
# plan_off($t): the local clock's offset from UTC at $t, in seconds.
def plan_off($t): ($t | floor | localtime | mktime) - ($t | floor);

# plan_until_epoch($now): a clock time as typed (`12:30`, `3`, `3pm`,
# `3:30pm`, `noon`) as its next occurrence after $now on the local clock; a
# 12-hour time without am or pm is whichever comes first. null when it is
# not a time.
def plan_until_epoch($now):
  ascii_downcase
  | (if . == "noon" or . == "midday" or . == "lunch" then "12:00" else . end)
  | (capture("^(?<h>[0-9]{1,2})(?::(?<m>[0-5][0-9]))?(?<ap>am|pm)?$") // null) as $c
  | if $c == null then null
    else ($c.h | tonumber) as $h | (($c.m // "0") | tonumber) as $mi
      | (if $c.ap != null then
           (if $h < 1 or $h > 12 then [] else [($h % 12) + (if $c.ap == "pm" then 12 else 0 end)] end)
         elif $h > 23 then []
         elif $h >= 1 and $h <= 12 then [$h % 12, ($h % 12) + 12]
         else [$h] end) as $hours
      | plan_off($now) as $off
      | (($now + $off) | floor | gmtime) as $lt
      # Today's and tomorrow's showing of each hour, each at the offset in
      # force then (read twice, so the second read is at the time itself):
      # across a daylight-saving change, tomorrow's is not 24 hours on.
      | [ $hours[]
          | ([$lt[0], $lt[1], $lt[2], ., $mi, 0, 0, 0] | mktime) as $wall
          | ($wall, $wall + 86400) as $w
          | $w - plan_off($w - plan_off($w - $off))
          | select(. > $now) ]
      | if length == 0 then null else min end
    end;

# plan_cost: a Decision's declared cost in minutes ("~10 min", "5m"); null
# when it declares none in minutes.
def plan_cost:
  (.cost // "") | ascii_downcase
  | (capture("(?<n>[0-9]+)\\s*(?:m|mins?|minutes?)\\b") // null)
  | if . == null then null else .n | tonumber end;

def plan_pace_text($p; $chunk):
  if $p == null then null
  elif $chunk != null then "\($p) min a \($chunk)"
  else "\($p) min each" end;

def plan_window_text($w):
  if $w % 60 == 0 then (if $w == 60 then "the last hour" else "the last \($w / 60) hours" end)
  else "the last \($w) min" end;

def plan_n($n; $one; $many): "\($n) " + (if $n == 1 then $one else $many end);

# desk_plan_propose: the proposal for one set of inputs. Input:
#   {inputs, forecast (plan forecast --json), decisions (list --kind decision
#    --status open --json), reviews (the items of list --kind reviews
#    --unreviewed --json), gap (minutes between blocks: the tick cadence),
#    batch_min (the clear-first budget, 10), stored (plan get --json's plan,
#    for a revision; else absent)}
# Output:
#   {inputs (with `end` resolved), missing ([] or ["item"] or ["pace"]),
#    now, forecast, batch {decisions, reviews, ids, minutes}, later [ids],
#    revision, pace, kept (a revision's stored blocks already over: [] for a
#    new plan), blocks [{item, label, pace, start, until, start_local,
#    until_local}] (the blocks to come), wanted and shortfall (null, or how
#    many blocks were asked for when fewer fit, and the card's line saying
#    why: the 24 cap, the extent's end, or the day), problem (null, or why
#    no block fits)}
# A new plan clears a batch first: the parked menu-shaped Decisions, then the
# other menu-shaped ones and then Reviews while they fit in batch_min (a
# Decision at its declared minutes, else 2; a Review at 2) and, with a
# morning check-in today, while the reading budget has some left (the
# forecast's `left`, #1770: none left, no Review in the batch). Long-form
# Decisions and what does not fit wait for the first block's end (`later`).
# The first block starts when the batch is done, and blocks are gap minutes
# apart, so a tick lands between them and shows what was held. No count,
# until, or for: one chunk. A new plan's `for` counts from the first block's
# start each time it is proposed, so the time taken to confirm it never
# shortens it. A revision (stored) keeps the stored batch, `later`, end, and
# the blocks already over (`kept`, which plan_record stores first, so a later
# revision still counts them), and plans the chunks still to do from now
# (from the first block's start, when none has begun): the old count less
# the blocks already over (none left is a problem, not one more), or a count
# named in the revision.
def desk_plan_propose:
  . as $c
  | ($c.forecast.now // (now | todate) | plan_epoch) as $now
  | (($c.gap // 5) | if type == "number" and . >= 1 then . else 5 end) as $gap
  | (($c.batch_min // 10) | if type == "number" and . >= 0 then . else 10 end) as $budget
  | ($c.inputs // {}) as $in
  | ([ ($c.decisions // [])[] | select(.kind == "decision" and .status == "open") ]) as $open
  | ($c.stored // null) as $st
  # Today's reading budget (#1770): the forecast's `left`, the Reviews still
  # to read today; null (no check-in today) leaves the batch as it was.
  | (($c.forecast // {}).left | if type == "number" then . else null end) as $rleft
  | (if $st != null then
       [ ($st.blocks // [])[] | {s: (.start | plan_epoch), u: (.until | plan_epoch)} ] as $sb
       | ([ $sb[] | select(.u <= $now) ] | length) as $done
       | (($sb | length) > 0 and $now < $sb[0].s) as $before
       | { decisions: [ ($st.clear_first // [])[] | select(startswith("D-")) ],
           reviews: [ ($st.clear_first // [])[] | select(startswith("R-")) ],
           ids: ($st.clear_first // []), minutes: 0, later: ($st.later // []),
           start: (if $before then $sb[0].s else ($now | plan_ceil_min) end),
           first: (if $before then 1 else $done + 1 end),
           done: (if $before then 0 else $done end),
           kept: [ ($st.blocks // [])[] | select((.until | plan_epoch) <= $now) ] }
     else
       ([ $open[] | select(menu_shaped) | {id, parked: (.parked == true), m: (plan_cost // 2)} ]) as $quick
       | ({dec: [], rev: [], m: 0}
          | reduce ($quick[] | select(.parked)) as $q (.; .dec += [$q.id] | .m += $q.m)
          | reduce ($quick[] | select(.parked | not)) as $q (.;
              if .m + $q.m <= $budget then .dec += [$q.id] | .m += $q.m else . end)
          | reduce (($c.reviews // [])[] | select(.kind == "review" and .status == "open")) as $r (.;
              if .m + 2 <= $budget and ($rleft == null or (.rev | length) < $rleft)
              then .rev += [$r.id] | .m += 2 else . end)) as $b
       | { decisions: $b.dec, reviews: $b.rev, ids: ($b.dec + $b.rev), minutes: $b.m,
           later: [ $open[] | .id as $i | select([ $b.dec[] | select(. == $i) ] | length == 0) | .id ],
           start: (($now + $b.m * 60) | plan_ceil_min), first: 1, done: 0, kept: [] }
     end) as $batch
  | $batch.start as $start
  | (if $in.item == null then ["item"]
     elif $in.pace_min == null and $in.until == null and $in.for_min == null and $in.end == null then ["pace"]
     else [] end) as $missing
  # A plan runs at most a day ahead (plan set refuses more): a time tomorrow
  # can be 25 hours on across the night the clocks fall back.
  | ((if $in.for_min != null and $in.until == null and $st == null then $start + $in.for_min * 60
      elif $in.end != null then ($in.end | plan_epoch)
      elif $in.until != null then ($in.until | plan_until_epoch($now))
      elif $in.for_min != null then $start + $in.for_min * 60
      else null end)
     | if . == null then null else [., $now + 86400] | min end) as $end
  | $in.pace_min as $p
  | (if $missing != [] or $p == null then null
     elif $in.count != null then
       (if $st != null and $in.count_given != true then [0, $in.count - $batch.done] | max else $in.count end)
     elif $end != null then [1, ((($end - $start) + $gap * 60) / (($p + $gap) * 60) | floor)] | max
     else 1 end) as $want
  # A revision keeps the blocks already over; all of them together stay
  # within plan set's 24.
  | (24 - ($batch.kept | length)) as $room
  | (if $missing != [] then []
     elif $p == null then
       (if $end != null and $end > $start and $room > 0 then [{s: $start, u: $end}] else [] end)
     else
       [ range(0; [$want, $room] | min) as $k
         | ($start + $k * ($p + $gap) * 60) as $s
         | {s: $s, u: (if $end != null then [$s + $p * 60, $end] | min else $s + $p * 60 end)}
         | select(.u > .s and .u <= $now + 86400) ]
     end) as $spans
  | ($spans | length) as $n
  # Fewer blocks than asked for: the 24 cap, the extent's end, or the day.
  | (if $want == null or $n == 0 or $want <= $n then null
     elif $n == ([$want, $room] | min) then "Only \($n) of the \($want) asked for fit: at most 24 blocks in a plan."
     elif $end != null then "Only \($n) of the \($want) asked for fit before \($end | plan_hm) ET."
     else "Only \($n) of the \($want) asked for fit within a day." end) as $short
  | ($batch.first + $n - 1) as $total
  | (plan_pace_text($p; $in.chunk) // (if $end != null then "one block until \($end | plan_hm)" else null end)) as $pace
  # A count named in a revision is the chunks still to do; the inputs store
  # the plan's whole count (those plus the blocks already over), which the
  # next revision subtracts the blocks over from again.
  | { inputs: ($in + {end: (if $end != null then ($end | plan_iso) else null end),
                      count: (if $st != null and $in.count_given == true and $in.count != null
                              then $in.count + $batch.done else $in.count end)}
               | del(.count_given)),
      missing: $missing,
      now: ($now | plan_iso),
      forecast: ($c.forecast // null),
      batch: ($batch | {decisions, reviews, ids, minutes}),
      later: $batch.later,
      revision: ($st != null),
      pace: $pace,
      kept: $batch.kept,
      blocks: [ $spans | to_entries[]
                | { item: $in.item,
                    label: (if $total > 1 then "\($in.chunk // "block") \($batch.first + .key) of \($total)"
                            elif $in.chunk != null then "\($in.chunk) \($batch.first + .key)"
                            else null end),
                    pace: $pace,
                    start: (.value.s | plan_iso), until: (.value.u | plan_iso),
                    start_local: (.value.s | plan_hm), until_local: (.value.u | plan_hm) } ],
      wanted: (if $short != null then $want else null end),
      shortfall: $short,
      problem: (if $missing == [] and $n == 0
                then (if $want == 0 then "every \($in.chunk // "block") planned is done; name how many more (`2 \($in.chunk // "block")s`)"
                      elif $end != null then "no block fits before \($end | plan_hm) ET"
                      else "no block fits" end)
                else null end) };

# budget_line: today's reading budget against what has been read (#1770),
# from anything carrying `budget`, `read_today`, and `left` (`checkin get
# --json`, `plan forecast --json`): "Reading budget: 9 of 28 Reviews read
# today · 19 left" (or "· 3 over"). Nothing without a check-in today.
def budget_line:
  if (.budget | type) != "number" then empty
  else "Reading budget: \(.read_today // 0) of \(.budget) Reviews read today · "
       + (if (.left // 0) >= 0 then "\(.left // 0) left" else "\(-.left) over" end)
  end;

# plan_forecast_lines: the proposal's "waiting now", reading budget (with a
# check-in today), and forecast lines.
def plan_forecast_lines:
  . as $p
  | .forecast as $f
  | if $f == null then empty
    else
      ([ (if ($f.open // 0) > 0 then plan_n($f.open; "open Decision"; "open Decisions")
            + (if ($f.parked // 0) > 0 then " (\($f.parked) parked)" else "" end) else empty end),
         (if ($f.unreviewed // 0) > 0 then plan_n($f.unreviewed; "unreviewed Review"; "unreviewed Reviews") else empty end) ]
       | if length == 0 then "Waiting now: nothing." else "Waiting now: " + join(" and ") + "." end),
      ($f | budget_line | . + "."),
      (($f.window_min // 180) as $w
       | ($f.asked // 0) as $a
       | if $a == 0 then "Forecast: no thread asked anything in \(plan_window_text($w)), so few new questions are likely."
         else ($a * 60 / $w) as $rate
           | ($p.blocks | last) as $last
           | (if $last == null then null
              else ((($last.until | plan_epoch) - ($p.now | plan_epoch)) / 3600 * $rate) | round end) as $expect
           | "Forecast: " + plan_n($f.threads // 0; "thread"; "threads") + " asked "
             + plan_n($a; "question"; "questions") + " in " + plan_window_text($w)
             + ", about " + (if $rate < 1 then "one every \((60 / $rate) | round) min" else "\($rate | round) an hour" end)
             + (if $expect == null then "."
                else " — about \($expect) more by \($last.until_local) ET, held until each block ends." end)
         end)
    end;

# plan_card: what the desk prints for a proposal: one blockquote (the
# prose-question nudge reads a blockquote as the desk's own card), then one
# line, outside it, saying how to reply.
def plan_card:
  if (.missing | index("item")) != null then
    ([ "**What are you working on, and how fast?**",
       "For example `the PRD, 30 min a section, 4 sections`, or `the deck until 12:30`." ] | quote)
    + "\n\nReply in one sentence; `no` drops it."
  elif (.missing | index("pace")) != null then
    ([ "**How fast will \(.inputs.item) go, and in what chunks?**",
       plan_forecast_lines,
       "For example `30 min a section, 4 sections`, `an hour a chapter, until 12:30`, or `for 90 min`." ] | quote)
    + "\n\nReply in one sentence; `no` drops it."
  elif .problem != null then
    ([ "**No plan for \(.inputs.item): \(.problem).**" ] | quote)
    + "\n\nChange it in one sentence (`until 13:00`, `20 min a section`), or `no` to drop it."
  else
    ([ "**" + (if .revision then "Plan revised: " else "Plan: " end) + .inputs.item
         + (if .pace != null then ", " + .pace else "" end)
         + (if .revision then "**" else " — sound right?**" end),
       plan_forecast_lines ]
     + ( [ (if .revision then empty
            elif (.batch.ids | length) > 0 then "Clear first, about \(.batch.minutes) min: \(.batch.ids | join(", "))."
            else "Nothing quick to clear first." end),
           (.blocks[] | "\(.start_local)–\(.until_local) ET · \(.item)" + (if .label != null then ", \(.label)" else "" end)
                        + " · everything held."),
           "Then what was held" + (if (.later | length) > 0 then ", and later: \(.later | join(", "))." else "." end) ]
         | to_entries | map("\(.key + 1). \(.value)") )
     + (if .shortfall != null then [ .shortfall ] else [] end)
     | quote)
    + "\n\n"
    + (if .revision then "Stored. Change it again in one sentence; `plan?` shows it, `plan off` drops it."
       else "Reply `yes` to keep this plan, or change it in one sentence (`4 sections`, `45 min a section`, `until 12:30`); `no` drops it." end)
  end;

# plan_record: the JSON `plan set` stores, from a proposal with blocks.
# A revision's blocks already over come first, as stored, so the next
# revision still counts them as done.
def plan_record:
  { item: .inputs.item, pace: .pace, inputs: .inputs,
    clear_first: .batch.ids, later: .later,
    blocks: ((.kept // []) + [ .blocks[] | {item, pace, start, until} + (if .label != null then {label} else {} end) ]) };

# plan_show: `plan get --json` ({now, today, plan}) as the `plan?` card.
def plan_show:
  (.now | plan_epoch) as $now
  | if .plan == null then "No plan for today."
    else .plan as $p
      | ([ "**Today's plan: \($p.item // "?")" + (if $p.pace != null then ", \($p.pace)" else "" end) + "**",
           (if (($p.clear_first // []) | length) > 0 then "Clear first: \($p.clear_first | join(", "))." else empty end) ]
         + [ ($p.blocks // []) | to_entries[]
             | (.value.start | plan_epoch) as $s | (.value.until | plan_epoch) as $u
             | "\(.key + 1). \($s | plan_hm)–\($u | plan_hm) ET · \(.value.item)"
               + (if .value.label != null then ", \(.value.label)" else "" end)
               + (if $u <= $now then " · over" elif $s <= $now then " · now, everything held" else "" end) ]
         + [ (if (($p.later // []) | length) > 0 then "Later: \($p.later | join(", "))." else empty end) ]
        | quote)
    end;

# ------------------------------------------------- the to-do layer (#1769)

# todo_line: the operator's own to-do fields on an item (any item JSON the
# CLI prints, migration 010): its personal priority, tags, and note as one
# line, `P2 · tags: prd, urgent · note: ask Sam first`, or empty when it
# carries none (as on a store before 010). The snooze is left out: it only
# hides the item from `my list`.
def todo_line:
  [ (.my_priority // empty | "P\(.)"),
    ((.my_tags // []) | if length > 0 then "tags: " + join(", ") else empty end),
    ((.my_note // "") | if . == "" then empty else "note: " + . end) ]
  | if length == 0 then empty else join(" · ") end;

# ------------------------------------- morning check-in and reading budget (#1770)
#
# The check-in (checkin.md): three answers in one typed line — hours at the
# desk today, energy in one word, anything planned — read by one grammar, so
# the desk never guesses them out of prose; the card that asks, the card that
# shows the budget once, and the Reviews view's running count. Input: `checkin
# get --json` ({today, checkin, measured, factors, guess, read_today,
# answered_today, unreviewed, budget, left}).

# num1: a number to one decimal, without a trailing ".0" ("7", "7.3").
def num1: (. * 10 | round) / 10 | tostring;

# checkin_hours: hours as typed ("4", "4.5", "4h", "4 hours", "four",
# "an hour", "half an hour", "4 and a half hours", "90 min", "none") as a
# number of hours (two decimals at most), else null. 0 to 16.
def checkin_hours:
  ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | sub("^(?:about|around|roughly|maybe|~) ?"; "")
  | sub("(?: (?:at the desk|at my desk|today))+$"; "")
  | if test("^(?:0|zero|none|no hours?)(?: ?(?:h|hrs?|hours?))?$") then 0
    else (capture("^(?<n>[0-9]{1,3}(?:\\.[0-9]{1,2})?|half an?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|ninety)"
                  + "(?: ?(?<u>h|hrs?|hours?|m|mins?|minutes?)\\b)?(?<half> and a half)?(?: (?<u2>h|hrs?|hours?))?$") // null)
      | if . == null then null
        else (.n | plan_num) as $v
          | if $v == null then null
            elif ((.u // "") | startswith("m")) then (if .half != null then null else $v / 60 end)
            else $v + (if .half != null then 0.5 else 0 end) end
        end
    end
  | if . == null or . < 0 or . > 16 then null else (. * 100 | round) / 100 end;

# checkin_energy: one word of energy as typed ("ok", "Pretty tired", "low.",
# "feeling low today") as the stored word: the last word of up to three,
# lowercase, after a trailing "today" / "now" / "right now" / "this morning"
# / "at the moment" is dropped; else null.
def checkin_energy:
  ascii_downcase | gsub("[.!]+$"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | sub("^energy ?[:=]? ?"; "")
  | sub("(?: (?:today|right now|now|this morning|at the moment))+$"; "")
  | split(" ") | if length >= 1 and length <= 3 then last else null end
  | if . != null and test("^[a-z][a-z-]{0,19}$") then . else null end;

# checkin_planned: the planned text as typed, trimmed; null for none. A
# leading `plan`/`plans`/`planned`/`planning` label is dropped only as a whole
# word (`plan: the deck`, `planning the offsite`), never out of a longer word
# (`planet visit`, `plant the garden` stay whole).
def checkin_planned:
  gsub("\\s+"; " ") | gsub("^ | $"; "") | sub("^(?i:planned|plans?|planning)(?:\\s*[:=]\\s*|\\s+|$)"; "")
  | if test("^(?i:none|nothing|no|nope|n/a|-|nothing planned|no plans?)?\\.?$") then null else . end;

# checkin_parse: the operator's whole reply to the check-in card (a string,
# as `jq -Rs` reads it) as
#   {"skip": bool, "hours": N|null, "energy": "word"|null,
#    "planned": "text"|null, "missing": ["hours"?, "energy"?]}
# The reply is `hours, energy, plan` — separated by commas, semicolons, or
# line breaks; the plan keeps any commas of its own (`4, ok, the PRD, 30 min
# a section`) and may be left out — or the same three separated by spaces
# (`4h ok the PRD`). `skip` (also `not today`, `no check-in`, `pass`) skips
# the check-in. A reply missing hours or energy names it in `missing`: it is
# not a check-in reply, and the desk treats it as an ordinary message.
def checkin_parse:
  (gsub("[’‘]"; "'") | gsub("^\\s+|\\s+$"; "")) as $m
  | ($m | ascii_downcase | sub("[.!]+$"; "")) as $l
  | if ($l | test("^(skip|skip it|skip today|skip the check-?in|not today|no check-?in|pass)$")) then
      {skip: true, hours: null, energy: null, planned: null, missing: []}
    else
      ([ $m | match("[,;\\n]"; "g") | .offset ]) as $cuts
      # Separated by commas, semicolons, or line breaks.
      | (if ($cuts | length) >= 1 then
           { h: $m[0:$cuts[0]],
             e: $m[($cuts[0] + 1):($cuts[1] // ($m | length))],
             p: (if ($cuts | length) >= 2 then $m[($cuts[1] + 1):] else null end) }
           | {hours: (.h | sub("^(?i:hours?)\\s*[:=]?\\s*"; "") | checkin_hours),
              energy: (.e | checkin_energy), planned: (.p | if . == null then null else checkin_planned end)}
         else null end) as $a
      # Separated by spaces (`4h ok the PRD, 30 min a section`): the longest
      # run of up to five leading words that reads as hours, the next word,
      # and the rest.
      | (($m | gsub("\\s+"; " ") | split(" ")) as $w
         | [ range([5, ($w | length) - 1] | min; 0; -1) as $k
             | ($w[:$k] | join(" ") | checkin_hours) as $h
             | select($h != null)
             | {hours: $h,
                energy: ($w[$k] | checkin_energy),
                planned: ($w[($k + 1):] | join(" ") | checkin_planned)} ] | .[0]) as $b
      | (def whole: . != null and .hours != null and .energy != null;
         if ($a | whole) then $a elif ($b | whole) then $b
         else $a // $b // {hours: ($m | checkin_hours), energy: null, planned: null} end) as $r
      | $r + {skip: false,
              missing: ([ (if $r.hours == null then "hours" else empty end),
                          (if $r.energy == null then "energy" else empty end) ])}
      | {skip, hours, energy, planned, missing}
    end;

# checkin_planned_plan: whether the planned text is a piece of work the day
# plan can schedule — an item with a pace or an extent (`the PRD, 30 min a
# section`, `the deck until 12:30`, `meetings until noon`) — by plan.md's
# own grammar (desk_plan_parse). Then the desk goes on into plan.md step 2
# with it.
def checkin_planned_plan:
  if type != "string" then false
  else desk_plan_parse("item").fields
    | .item != null and (.pace_min != null or .until != null or .for_min != null or .count != null)
  end;

# checkin_day_text: a YYYY-MM-DD day as "Thu Oct 8".
def checkin_day_text: day_epoch | if . == null then "?" else strftime("%a %b %d") | sub(" 0(?<n>[1-9])$"; " \(.n)") end;

# checkin_hours_text: hours as "4 h", "1.5 h", "30 min".
def checkin_hours_text:
  if type != "number" then "?"
  elif . > 0 and . < 1 then "\(. * 60 | round) min"
  else "\(num1) h" end;

# checkin_active_text: minutes at the desk as "45 min" or "1.5 h" (to the
# half hour).
def checkin_active_text:
  if . < 60 then "\(.) min" else "\(. / 30 | round | . / 2 | num1) h" end;

# checkin_pace_line: the measured day's numbers as one line, or why there
# are none.
def checkin_pace_line:
  .today as $today
  | if .measured == null then
      "No measured pace yet: no day in the last \(.guess.lookback_days // 7) has \(.guess.min_read // 3) Reviews read,"
      + " so today starts from the \(.guess.items // 30) × \(.guess.lines_per_item // 20) guess."
    else .measured as $m
      | ($m.day | day_label($today)) as $d
      | (if $d == "Yesterday" then "Yesterday" else "Last measured day, \($d)" end)
        + ": \(plan_n($m.reviewed; "Review"; "Reviews")) read in about \($m.active_min | checkin_active_text) at the desk,"
        + " \($m.reviews_per_hour | num1) an hour"
        + (if ($m.answered // 0) > 0 then
             "; \(plan_n($m.answered; "Decision"; "Decisions")) answered"
             + (if $m.median_shown_to_answered_min != null
                then ", median \($m.median_shown_to_answered_min | num1) min from shown to answered" else "" end)
           else "" end)
        + "."
    end;

# checkin_card: the morning check-in's card (`checkin get --json`): the
# measured pace, what waits, and the three questions, as one blockquote; then
# how to reply. With today's check-in stored (`check-in` again), it says what
# is stored and that a new answer replaces it.
def checkin_card:
  ([ "**" + (if .checkin != null then "Check-in again" else "Morning check-in" end)
       + " · \(.today | checkin_day_text)**",
     checkin_pace_line,
     (if .checkin != null then
        "Now: \(.checkin.hours | checkin_hours_text), energy \(.checkin.energy), budget \(.checkin.budget)"
        + " (\(.read_today // 0) read). A new answer replaces it."
      else empty end),
     "Waiting now: " + (if (.unreviewed // 0) > 0 then plan_n(.unreviewed; "unreviewed Review"; "unreviewed Reviews") else "no unreviewed Reviews" end) + ".",
     "1. Hours at the desk today?",
     "2. Energy, in one word? (for example low, ok, high)",
     "3. Anything planned? (a piece of work and its pace, meetings, or none)" ] | quote)
  + "\n\nReply in one line, `hours, energy, plan`: `4, ok, the PRD until noon`. `skip` "
  + (if .checkin != null then "keeps the one stored." else "leaves today without a reading budget." end);

# budget_card: the reading budget, shown once after the check-in is stored
# (`checkin set --json`, the same shape as get), and on `budget?`. Without a
# check-in today, one line saying so.
def budget_card:
  if .checkin == null then "No check-in today, so no reading budget. Say `check-in` to set one."
  else .checkin as $c
    | (.today // $c.day) as $today
    | ($c.factor | if type == "number" then num1 else "1" end) as $f
    | ("energy \($c.energy) (" + (if $c.factor_known == false then "not in the table: 1" else $f end) + ")") as $e
    | ([ "**Reading budget today: \(plan_n($c.budget; "Review"; "Reviews"))"
           + (if ($c.lines // 0) > 0 then " (~\($c.lines) lines at level 2)" else "" end) + "**",
         (if $c.hours == 0 then "0 h at the desk today: nothing to read."
          elif ($c.basis.kind // "") == "measured" then
            (($c.basis.day | day_label($today)) as $d
             | (if $d == "Yesterday" then "Yesterday's pace" else "The pace on \($d)" end))
            + ", \($c.basis.rate | num1) an hour × \($c.hours | checkin_hours_text) × \($e) = \($c.budget)."
          else "The starting guess, \($c.basis.items // 30) Reviews (no measured pace yet) × \($e) = \($c.budget)." end),
         "\(.unreviewed // 0) waiting now · \(.read_today // 0) read so far today"
           + (if (.left | type) == "number" and .left < 0 then " · \(-.left) over" else "" end) + ".",
         (if $c.planned != null then "Planned: \($c.planned)" else empty end) ] | quote)
    + "\n\n`reviews` keeps the running count against it; `check-in` changes the hours or the energy; `budget?` shows this again."
  end;

# reviews_view_budget($chk): reviews_view (its input, `list --kind reviews
# --unreviewed --json`) with today's running count under its header, from
# $chk (`checkin get --json`, or null): exactly reviews_view without a
# check-in today.
def reviews_view_budget($chk):
  reviews_view as $v
  | ([ ($chk // {}) | budget_line ] | .[0]) as $b
  | if $b == null then $v
    elif ((.items // []) | length) == 0 then $v + "\n" + $b + "."
    else ($v | split("\n")) as $l | ([ $l[0], $b ] + $l[1:]) | join("\n") end;

# ---------------------------------------------------- end-of-day sweep (#1784)

# sweep_lines($set): `sweep list --json` as the sweep's numbered lines, one
# per item: a Decision's question with its repository and key, a Review's
# cached line (else its title). An item that carries the operator's own
# priority, tags, or note (#1769) gets one nested line under it, `   - ` and
# its todo_line, so the paper copy carries them too. $set is set-open's JSON
# for these items (its numbers are the ones replies resolve against), or null
# when no set could be opened (then the list's own order numbers them, and
# replies use ids).
def sweep_lines($set):
  ([ (($set // {}).items // [])[] | {key: .id, value: .n} ] | from_entries) as $num
  | [ (.items // []) | to_entries[]
      | ($num[.value.id] // (.key + 1)) as $n
      | .value
      | (if .kind == "review" then
           "\($n). \(.id) · \(review_label) · "
           + (if (.summary_l1 // "") != "" then .summary_l1 else .question + " (title; not summarized yet)" end)
         else
           "\($n). \(.id) · \(.question) (\(.repo | split("/") | .[1] // .) · \(.key))"
           + (if menu_shaped then "" else " · long-form" end)
           + (if .parked then " · parked" else "" end)
         end),
        ("   - " + todo_line) ]
  + (if (.more // 0) > 0 then ["… and \(.more) more; `sweep` lists them once some are cleared."] else [] end);

# sweep_view($set): the end-of-day card: a bold header and the numbered list
# as one blockquote, then one line on replying and taking it to paper.
def sweep_view($set):
  if ((.items // []) | length) == 0 then "End of day: nothing is open."
  else
    ([ "**End of day · " + plan_n(.count; "item"; "items") + " still open"
         + (if $set != null then " · set \($set.set_id)" else "" end) + "**" ]
     + sweep_lines($set) | quote)
    + "\n\n"
    + (if $set != null then "Reply by number or id any time (`2: B`, `D-43: B`, `reviewed R-7`)."
       else "Reply by id any time (`D-43: B`, `reviewed R-7`)." end)
    + " Take it to paper: say `export` for a numbered PDF (#1759)."
  end;
