# desk/skill/desk.jq — the /desk skill's deterministic item logic (issues
# #1779, #1780, #1783): which Decisions fit a menu, how the simple ones chunk
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
#         (fixtures) and desk/tests/interrupts.test.sh (live).

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
# in the latest set (1 to 99) or its id, uppercased.
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
