# desk/skill/desk.jq — the /desk skill's deterministic item logic (issues
# #1779, #1780): which Decisions fit a menu, how the long-form ones group into
# multipart items, and the exact text of a long-form card and a discussion
# card. One file, so the menus and the long-form view share one predicate, and
# the tests run these functions themselves rather than copies of them.
#
# Use:    jq -L "$DESK/skill" 'include "desk"; <function>'
# Input:  the CLI's item JSON — `list --json` arrays, `get --json` objects.
# Tests:  desk/tests/longform-offline.test.sh (fixtures),
#         desk/tests/longform.test.sh (live, throwaway schema).

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
def desk_split($ids):
  ($ids | split(" ") | map(select(. != ""))) as $want
  | [ to_entries[]
      | select(.value.kind == "decision" and .value.status == "open")
      | select(($want | length) == 0 or (.value.id as $i | any($want[]; . == $i)))
      | {n: .key, item: .value} ] as $rows
  | { simple: [ $rows[] | select(.item | menu_shaped) | .item.id ],
      longform: ( [ $rows[]
                    | select(.item | menu_shaped | not)
                    | {n, id: .item.id, g: [.item.repo, .item.key, .item.session_id]} ]
                  | group_by(.g) | map(sort_by(.n)) | sort_by(.[0].n)
                  | map(map(.id)) ) };

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
