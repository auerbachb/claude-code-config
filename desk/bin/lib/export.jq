# desk/bin/lib/export.jq — the paper copy of a batch (issue #1759): one item
# model and three renderings of it, Markdown, plain text, and HTML. Loaded by
# `human-queue.sh export` with
#   jq -L desk/bin/lib -L desk/skill 'include "export"; export_markdown'
# Input: the export's own JSON (export --help, "THE MODEL"): the batch's set,
# its export time, and its items, each with its number `n` in the set.
#
# Layout (ISO 2145): item n's heading starts with `n` and its id; its options
# are `n.1`, `n.2`, … each with the letter a typed reply uses (`2.2  B. No`).
# Every open item ends in a blank answer line; the footer carries the export
# time. Reuses desk.jq (letter, bare_label, utc, item_link, default_line,
# review_label, menu_shaped, short_repo), so the paper and the screen agree
# on every label.

include "desk";

def ex_plural($n; $one; $many): "\($n) " + (if $n == 1 then $one else $many end);

# ex_title: what the batch is.
def ex_title:
  if .source == "decisions" then "Decisions"
  elif .source == "reviews" then "Reviews"
  elif .source == "set" then "Set \(.set_id)"
  else "Selected items" end;

def ex_has_reviews: any((.items // [])[]; .kind == "review");

def ex_subtitle:
  [ (if .set_id != null then "set \(.set_id)" else empty end),
    ex_plural(.count; "item"; "items"),
    (if ex_has_reviews then "Reviews at level \(.level)" else empty end),
    "exported \(.exported_local) ET" ]
  | join(" · ");

def ex_hint:
  "Reply at the desk by id (D-43: B; a Review: reviewed R-9, or flag R-9 \"why\")"
  + (if .set_id != null
     then ", or by number (2: B) while set \(.set_id) is the desk's latest set."
     else "." end);

def ex_more:
  if (.more // 0) > 0
  then "… and \(ex_plural(.more; "more item"; "more items")) left out (an export holds at most 99)."
  else empty end;

def ex_footer:
  [ "Exported \(.exported_local) ET",
    (if .set_id != null then "set \(.set_id)" else empty end),
    ex_plural(.count; "item"; "items") ]
  | join(" · ");

# ex_todo: the operator's own priority, tags, and note on an item (#1769,
# migration 010) as one line, `P2 · tags: prd, urgent · note: ask Sam
# first`; empty when it carries none, or on a store before 010. The same
# line desk.jq's todo_line prints on the screen, kept here so this file does
# not depend on the order #1769 and #1759 merge in.
def ex_todo:
  [ (.my_priority // empty | "P\(.)"),
    ((.my_tags // []) | if length > 0 then "tags: " + join(", ") else empty end),
    ((.my_note // "") | if . == "" then empty else "note: " + . end) ]
  | if length == 0 then empty else join(" · ") end;


# ex_body($level): a Review's summary at $level, else the next level down,
# marked, so a line that is only a title is never mistaken for a summary.
def ex_body($level):
  (.summary_l2 // "") as $l2 | (.summary_l1 // "") as $l1
  | if $level >= 2 and $l2 != "" then $l2
    elif $l1 != "" then
      $l1 + (if $level >= 2 then "\n(level-2 summary not written yet; its one-line summary is shown)" else "" end)
    else .question + "\n(title; not summarized yet)" end;

# ex_item($level; $repos): one item, every field the three renderings print.
# $repos: every item's repository, so a repository shows without its owner
# unless another one in the batch has the same name (desk.jq's short_repo).
def ex_item($level; $repos):
  (.n | tostring) as $n
  | .default_option as $d
  | {
      n: $n,
      id: .id,
      kind: .kind,
      open: (.status == "open"),
      heading: (if .kind == "review" then .id + " · " + review_label else .id + " · " + .question end),
      meta: ([ (.repo // "" | if . == "" then "" else short_repo($repos) end),
               (if .kind == "review" then ((.context // [])[1] // empty) else .key end),
               (if .status != "open" then .status else empty end),
               (if .kind == "decision" then
                  (if .parked then "parked" else empty end),
                  (if menu_shaped then empty else "long-form" end),
                  (.impact_declared // empty | "Impact: " + .),
                  (.cost // empty | "Cost: " + .),
                  (.focus // empty | "Focus: " + .)
                else empty end) ]
             | map(select(. != "")) | join(" · ")),
      context: (if .kind == "decision" then (.context // []) else [] end),
      options: [ (.options // []) | to_entries[]
                 | { num: ($n + "." + (.key + 1 | tostring)), letter: letter(.key),
                     text: (.value | bare_label), recommended: (.value == $d) } ],
      default: ([ default_line ] | .[0]),
      body: (if .kind == "review" then ex_body($level) else null end),
      todo: ([ ex_todo ] | .[0]),
      link: item_link,
      answer: (if .status == "open" then null else (.answer // null) end),
      answer_label: (if .kind == "review" then "Reviewed [ ]   Flag, and why:" else "Answer:" end)
    };

def ex_items:
  .level as $level
  | [ (.items // [])[] | .repo // empty | select(. != "") ] as $repos
  | [ (.items // [])[] | ex_item($level; $repos) ];

def ex_option_text: .num + "  " + .letter + ". " + .text + (if .recommended then " (Recommended)" else "" end);

def ex_rule: "______________________________________________________________";

# ------------------------------------------------------------- Markdown

# ex_md_esc: text with every character Markdown reads as markup
# backslash-escaped: emphasis and code, links and images, raw HTML and
# entities, math, sub- and superscripts, heading attributes, tables.
def ex_md_esc: gsub("(?<c>[\\\\`*_{}\\[\\]<>#!$~^|&])"; "\\\(.c)");

# ex_md_lit: an item's own text (it comes from agent threads and GitHub) as
# Markdown pandoc reads literally, on one line: the paper shows the text as
# stored, an image in it is never fetched, and nothing in it reaches the PDF
# engine as TeX.
def ex_md_lit: tostring | gsub("[\r\n]+"; " ") | ex_md_esc;

# ex_md_body: a Review's summary, escaped the same way except its **bold**
# runs, which the desk writes on purpose; its lines stay lines.
def ex_md_body: tostring | ex_md_esc | gsub("\\\\\\*\\\\\\*"; "**");

# The item's own text goes through ex_md_lit (ex_md_body for a summary); the
# export's own words and rules do not. Lines that must stay lines end in two
# spaces (a Markdown line break), which reads as nothing on paper when the
# Markdown itself is printed.
def ex_md_item:
  "## " + .n + "  " + (.heading | ex_md_lit),
  "",
  (if .meta != "" then (.meta | ex_md_lit), "" else empty end),
  (if (.context | length) > 0 then (.context[] | "- " + ex_md_lit), "" else empty end),
  (if .body != null then (.body | ex_md_body | split("\n")[] | . + "  "), "" else empty end),
  (if (.options | length) > 0 then (.options[] | .text |= ex_md_lit | ex_option_text + "  "), "" else empty end),
  (if .default != null then (.default | ex_md_lit), "" else empty end),
  (if .todo != null then (.todo | ex_md_lit), "" else empty end),
  (if .link != null then "Link: " + (.link.label | ex_md_lit) + " — " + (.link.url | ex_md_lit), "" else empty end),
  (if .open then .answer_label + " " + ex_rule, "", ex_rule, ""
   elif .answer != null then "Answered: " + (.answer | ex_md_lit), ""
   else empty end);

def export_markdown:
  ([ "# Desk export · " + ex_title,
     "",
     ex_subtitle,
     "",
     ex_hint,
     "",
     (ex_items[] | ex_md_item),
     (ex_more | ., ""),
     "---",
     "",
     ex_footer ]
   | join("\n")) + "\n";

# ----------------------------------------------------------- plain text

def ex_txt_item:
  .n + "  " + .heading,
  (if .meta != "" then "   " + .meta else empty end),
  (.context[] | "   - " + .),
  (if .body != null then (.body | split("\n")[] | "   " + gsub("\\*\\*"; "")) else empty end),
  (.options[] | "   " + ex_option_text),
  (if .default != null then "   " + .default else empty end),
  (if .todo != null then "   " + .todo else empty end),
  (if .link != null then "   Link: " + .link.label + " — " + .link.url else empty end),
  (if .open then "", "   " + .answer_label + " " + ex_rule[0:40], "", "   " + ex_rule[0:60]
   elif .answer != null then "   Answered: " + .answer
   else empty end),
  "";

def export_text:
  ("Desk export · " + ex_title) as $t
  | ([ $t,
       ($t | gsub("."; "=")),
       ex_subtitle,
       ex_hint,
       "",
       (ex_items[] | ex_txt_item),
       (ex_more | ., ""),
       "--",
       ex_footer ]
     | join("\n")) + "\n";

# ----------------------------------------------------------------- HTML

def ex_h: tostring | @html;

# ex_html_bold: a summary line with its **bold** runs as <strong>, escaped
# first, so nothing in the text becomes markup.
def ex_html_bold: ex_h | gsub("\\*\\*(?<b>[^*]+)\\*\\*"; "<strong>\(.b)</strong>");

def ex_html_item:
  "<section class=\"item\">"
  + "<h2><span class=\"num\">" + (.n | ex_h) + "</span> " + (.heading | ex_h) + "</h2>"
  + (if .meta != "" then "<p class=\"meta\">" + (.meta | ex_h) + "</p>" else "" end)
  + (if (.context | length) > 0
     then "<ul class=\"context\">" + ([ .context[] | "<li>" + ex_h + "</li>" ] | join("")) + "</ul>"
     else "" end)
  + (if .body != null
     then "<div class=\"body\">" + ([ .body | split("\n")[] | "<p>" + ex_html_bold + "</p>" ] | join("")) + "</div>"
     else "" end)
  + (if (.options | length) > 0
     then "<ul class=\"options\">"
          + ([ .options[] | "<li><span class=\"num\">" + (.num | ex_h) + "</span> <b>" + (.letter | ex_h) + ".</b> "
                            + (.text | ex_h) + (if .recommended then " <em>(Recommended)</em>" else "" end) + "</li>" ]
             | join(""))
          + "</ul>"
     else "" end)
  + (if .default != null then "<p class=\"default\">" + (.default | ex_h) + "</p>" else "" end)
  + (if .todo != null then "<p class=\"todo\">" + (.todo | ex_h) + "</p>" else "" end)
  + (if .link != null then "<p class=\"link\">" + (.link.label | ex_h) + " — " + (.link.url | ex_h) + "</p>" else "" end)
  + (if .open then "<div class=\"answer\"><span>" + (.answer_label | ex_h) + "</span></div><div class=\"line\"></div>"
     elif .answer != null then "<p class=\"answered\">Answered: " + (.answer | ex_h) + "</p>"
     else "" end)
  + "</section>";

# The footer is a page-margin box, so it prints on every page. A CSS string
# needs its own escaping: backslashes and quotes, and no line break.
def ex_css_string: tostring | gsub("(?<c>[\\\\\"])"; "\\\(.c)") | gsub("[\r\n]"; " ") | "\"" + . + "\"";

def export_html:
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  + "<title>" + ("Desk export · " + ex_title | ex_h) + "</title>\n<style>\n"
  + "@page { size: letter; margin: 0.7in 0.75in 0.8in;"
  + " @bottom-left { content: " + (ex_footer | ex_css_string) + "; font: 8.5pt -apple-system, Helvetica, Arial, sans-serif; color: #444; }"
  + " @bottom-right { content: \"Page \" counter(page) \" of \" counter(pages); font: 8.5pt -apple-system, Helvetica, Arial, sans-serif; color: #444; } }\n"
  + "body { font: 10.5pt/1.4 -apple-system, Helvetica, Arial, sans-serif; color: #111; margin: 0; }\n"
  + "h1 { font-size: 15pt; margin: 0 0 4pt; }\n"
  + "p { margin: 2pt 0; } .sub { color: #333; } .hint { color: #333; font-size: 9.5pt; margin-bottom: 10pt; }\n"
  + "section.item { border-top: 1px solid #999; padding: 8pt 0 14pt; break-inside: avoid; }\n"
  + "h2 { font-size: 12pt; margin: 0 0 3pt; } h2 .num { display: inline-block; min-width: 2.2em; }\n"
  + ".meta, .default, .todo, .link { color: #333; font-size: 9.5pt; }\n"
  + ".link { word-break: break-all; }\n"
  + "ul { margin: 3pt 0; padding-left: 1.4em; } ul.options { list-style: none; padding-left: 0; }\n"
  + "ul.options .num { display: inline-block; min-width: 3em; }\n"
  + ".body p { margin: 1pt 0; }\n"
  + ".answer { margin-top: 8pt; border-bottom: 1px solid #000; height: 1.6em; }\n"
  + ".answer span { font-size: 9.5pt; color: #333; }\n"
  + ".line { border-bottom: 1px solid #000; height: 1.6em; }\n"
  + ".answered { font-style: italic; }\n"
  + "</style></head><body>\n"
  + "<h1>" + ("Desk export · " + ex_title | ex_h) + "</h1>\n"
  + "<p class=\"sub\">" + (ex_subtitle | ex_h) + "</p>\n"
  + "<p class=\"hint\">" + (ex_hint | ex_h) + "</p>\n"
  + ([ ex_items[] | ex_html_item ] | join("\n")) + "\n"
  + ([ ex_more | "<p class=\"more\">" + ex_h + "</p>\n" ] | join(""))
  + "</body></html>\n";

# --------------------------------------------------------------- summary

# export_missing: the Reviews in the batch with no summary at the export's
# level, by id (export --json's `missing_summary`; the desk writes them first).
def export_missing:
  .level as $level
  | [ (.items // [])[] | select(.kind == "review")
      | select(((if $level >= 2 then .summary_l2 else .summary_l1 end) // "") == "") | .id ];
