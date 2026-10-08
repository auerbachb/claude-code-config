# /desk — the Reviews view: `reviews`, `open`, `diff`, `reviewed`, `flag`

Loaded when the operator's whole message is one of the Reviews verbs below (`SKILL.md`, "Replies the operator types"). Reviews are landed work, one `R-<n>` per merged PR and per captured issue, pulled from GitHub by `sync-reviews` (#1756). The operator works through them at the depth they choose: one line each, twenty lines on `open`, the diff on `diff`. Every Bash block starts with `SKILL.md`'s prelude. Issue #1782; design: `desk/DESIGN.md` 2.5 (summaries lazy and layered, the diff never stored) and 2.7, mockup 6.3.

| The operator types | What happens |
|--------------------|--------------|
| `reviews` | Sync, write any missing one-line summaries once, and print the view: one line per unreviewed item, grouped by day and repo |
| `reviews since <YYYY-MM-DD>` | The same, with the first sync's window (only needed once, ever) |
| `open R-<n>` | Level 2: the twenty-line summary, generated once and cached |
| `diff R-<n> [path]` | Level 3: the diff (or one file of it), fetched live, never stored |
| `reviewed R-<n>`, or `reviewed` alone | Marks that Review reviewed (alone: the Review last opened or diffed here) |
| `reviewed all today` | Marks every Review synced today that is still unreviewed |
| `flag R-<n> "what to follow up"` | Flags it with that note, then offers a follow-up issue |
| `follow up R-<n>` | Files the follow-up issue for a flagged Review in its own repo (`follow up R-<n> again` after a filing that was never recorded) |

**Out of scope here:** interrupts, the interrupt policy, and feedback tags are `interrupts.md` (#1783); the day plan and the end-of-day sweep are `plan.md` and `sweep.md` (#1784); the numbered file-to-hunk outline and "ask about this PR" are #1768. None of them has a verb in this file.

## Rules for every verb

- **The CLI is the only writer.** Every summary, `reviewed`, `flagged`, and comment goes through `"$HQ"`; nothing is kept in this conversation as state, and no level-3 output is written anywhere.
- **Summaries are lazy.** Level 1 is written the first time an item is listed, level 2 the first time it is opened; both are cached and never written again (`summary set` refuses a second, different text). Nothing is ever summarized at wrap time.
- **Free text never goes inside the command's own quotes.** A summary, a note, a path, or an issue body is written through a quoted here-document (no expansion happens inside one), exactly as `decisions.md` passes replies.
- **A here-document's text never holds its own delimiter.** A line that is exactly the block's delimiter (`DESK_BODY`, `DESK_NOTE`, `DESK_L1`, …) would end the here-document early, and every line after it would run as shell. Before running a block, check the text: if any line equals the delimiter, pick another one that no line of the text equals, for both lines.
- **Plain text only, never AskUserQuestion.** In the desk's own session the capture hook queues any menu that does not carry the desk's `N. [D-id]` prefix as a new Decision.
- **No state line.** Print what was asked for and the one line each step names, nothing else (`desk/DESIGN.md` 4.1.4).
- **Exit 7** from any `"$HQ"` call → `Store unreachable — can't <verb> right now.` and stop; nothing is retried in a loop.

## `reviews`: the view, one line per item

### 1. Sync

<!-- test-anchor: desk-reviews-sync -->

```bash
"$HQ" sync-reviews >/dev/null; echo "exit=$?"
```

It adds a Review for each PR merged and each captured issue filed since the last sync (`desk/README.md`, "Sync"); its own output is not shown, because the view shows every item.

- `exit=0` → step 2.
- `exit=4` naming `--since` → Reviews have never been synced, and where they begin is the operator's call: say `Reviews have never been synced. Reply "reviews since 2026-10-01" (any date) to choose where they begin.` and stop. On `reviews since <date>`, accept only a `YYYY-MM-DD` date (anything else → one line asking for one), run `"$HQ" sync-reviews --since <date> >/dev/null; echo "exit=$?"`, then step 2.
- `exit=1` (GitHub failed, one stderr line) → one line, `Couldn't pull new Reviews from GitHub (<the line>) — showing what's stored.`, then step 2 anyway.

### 2. Write the missing one-line summaries, once

<!-- test-anchor: desk-reviews-l1-material -->

```bash
VIEW=$("$HQ" list --kind reviews --unreviewed --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  printf '%s\n' "$VIEW" | jq -r -L "$DESK/skill" 'include "desk"; reviews_missing_l1' \
    | while IFS=$'\x1f' read -r ID REPO KEY; do
        echo "===== $ID"
        "$DESK/bin/pr-summary-material.sh" "$REPO" "$KEY" --level 1 </dev/null; echo "exit=$?"
      done
fi
```

Nothing printed → every item already has its line: step 3. Otherwise each `===== R-<n>` section is that item's level-1 material: the title, labels, and the issue it closes (a PR), or the title, labels, and a body excerpt (an issue). For each one whose material ended in `exit=0`, write **one line** and cache it:

- What the change lets someone do, or what the captured issue asks for, functionally: `Facts store: facts are typed, carry their source, and conflicts are kept rather than overwritten.` Not how it is built.
- At most about 160 characters (200 is the store's limit), one line, no file paths, hashes, or PR numbers (the view prints the number beside it), and nothing the material does not support.

<!-- test-anchor: desk-reviews-l1-cache -->

```bash
"$HQ" summary set R-3 --level 1 <<'DESK_L1'
<the one line>
DESK_L1
echo "exit=$?"
```

Several items' blocks may run in one Bash call, one here-document each. `exit=0` → cached. `exit=4` `already has a level-1 summary` → another desk wrote it first; theirs stands. Any other `exit=4` → the line broke the shape (its stderr line says how): fix it and run the block again. An item whose material failed (`exit=1` GitHub, `exit=3` gone) gets no line this time; the view prints its title, and the next `reviews` tries again. Never stop the view over one item.

### 3. Print the view

<!-- test-anchor: desk-reviews-view -->

```bash
VIEW=$("$HQ" list --kind reviews --unreviewed --json); rc=$?
if [ "$rc" -eq 0 ]; then printf '%s\n' "$VIEW" | jq -r -L "$DESK/skill" 'include "desk"; reviews_view'; else echo "exit=$rc"; fi
```

Print its output as is, nothing before or after it:

```text
Reviews · 4 unreviewed · ~80 lines at level 2

Today · claude-code-config (2)
R-12 · PR #1787 · Reviews are pulled from GitHub, so a merged PR needs no thread to report it.
R-13 · Issue #1790 · Captured issue: the desk files an idea as an issue without capture mode.

Yesterday · sales-kit (1)
R-9 · PR #283 · Procedures can be instantiated, checked for completion, and moved to a new version.

Next: open R-<n> · diff R-<n> [path] · reviewed R-<n> · reviewed all today · flag R-<n> "…"
```

The day is the day the item was synced (America/New_York), newest first; inside a day, repositories by name (the owner is shown only when two repositories share a name); inside a group, oldest item first. An item still without its line shows its title, marked `(title; not summarized yet)`. With nothing unreviewed the block prints `No unreviewed Reviews.`, which is the whole reply.

## `open R-<n>`: level 2, cached

<!-- test-anchor: desk-open -->

```bash
ITEM=$("$HQ" get R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" 'include "desk"; review_header'
  if printf '%s\n' "$ITEM" | jq -e '.summary_l2 != null' >/dev/null; then
    printf '\n%s\n' "$(printf '%s\n' "$ITEM" | jq -r '.summary_l2')"
  else
    echo "LEVEL 2 NOT CACHED — material follows"
    "$DESK/bin/pr-summary-material.sh" "$(printf '%s\n' "$ITEM" | jq -r .repo)" \
      "$(printf '%s\n' "$ITEM" | jq -r .key)" --level 2; echo "exit=$?"
  fi
fi
```

- **Cached** (no `LEVEL 2 NOT CACHED` line): print the output as is, then the hint line below. The block made no GitHub call: the cached summary is the whole answer, every time.
- **Not cached**: the material follows (size, body, commits, files with line counts, tests touched, links; for an issue, its body and link). Write the summary in the operator's shape and cache it with the block below.
- `exit=1` from the material (GitHub failed) or `exit=3` (the PR or issue is gone) → one line naming it, and nothing is cached: `Couldn't load R-2 from GitHub (<the line>) — try "open R-2" again later.` No partial summary.
- `exit=4` from `get` → `R-2: no such Review.`

The shape (`summary --help`, checked when it is cached):

- Line 1, one bold statement of the change, functionally: `**Facts store: facts are typed, carry their source, and conflicts are kept.**`
- Then numbered points, about twenty lines in all: **what changed** (functionally, not file by file), **judgment calls** the agent made, **deferred** work, **tests**, and **links** (the PR, the issue it closes). A point may continue on indented lines.
- **Never invent.** When the material has no evidence for a point (no judgment call is described, nothing is deferred, no test file changed), say so in that point (`Judgment calls: none stated in the PR`). An issue has no tests or judgment calls of its own: say what it asks for, its acceptance criteria, and its link.

<!-- test-anchor: desk-open-cache -->

```bash
"$HQ" summary set R-2 <<'DESK_SUMMARY'
<the level-2 summary>
DESK_SUMMARY
echo "exit=$?"
```

`exit=0` → print the header lines, a blank line, and the summary exactly as cached, then the hint. `exit=4` `already has a level-2 summary` → another desk cached one first: run the `open` block again and print what it shows. Any other `exit=4` → the shape was refused (its line says why): fix it and cache again. Never print a summary the store refused as if it were cached.

The hint, one line: `diff R-2 [path] for the code · reviewed · flag R-2 "…"`. Remember R-2 as the item on screen, for a bare `reviewed`.

## `diff R-<n> [path]`: level 3, never stored

<!-- test-anchor: desk-diff -->

```bash
ITEM=$("$HQ" get R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  DIFF_PATH_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-diff-path.XXXXXX")
  cat > "$DIFF_PATH_FILE" <<'DESK_PATH'
<the path the operator named, or nothing>
DESK_PATH
  DIFF_PATH=$(cat "$DIFF_PATH_FILE"); rm -f "$DIFF_PATH_FILE"
  set -- "$(printf '%s\n' "$ITEM" | jq -r .repo)" "$(printf '%s\n' "$ITEM" | jq -r .key)" --level 3
  if [ -n "$DIFF_PATH" ]; then set -- "$@" --path "$DIFF_PATH"; fi
  printf '%s\n' "$ITEM" | jq -r -L "$DESK/skill" 'include "desk"; review_header'
  "$DESK/bin/pr-summary-material.sh" "$@"; echo "exit=$?"
fi
```

The material is fetched from GitHub every time and goes nowhere but the reply: nothing here writes to the store or to a file that outlives the block.

- **A PR:** print the header, then a numbered list of the files the diff touches (`1. desk/bin/cmd/review.sh`, from its `diff --git` lines), then the diff itself in a ```` ```diff ```` fence, exactly as fetched. A `[truncated: …]` line means it hit the size cap: say so after the fence and suggest `diff R-2 <path>` for one file.
- **An issue:** an issue has no diff; level 3 is its full body. Print the header, one line `R-2 is an issue: no diff. Its full body:`, then the body as fetched.
- `exit=3` → with a path, `<path> is not in R-2's diff.` (the PR or issue being gone reads `R-2 is no longer on GitHub.`); `exit=1` → `Couldn't load R-2's diff (<the line>).` (GitHub declines to render a very large diff: narrow it with a path); `exit=4` from `get` → `R-2: no such Review.`

Then the same hint line as `open`, and remember R-2 as the item on screen.

## `reviewed`

- `reviewed R-<n>` → that Review. `reviewed` alone → the Review last opened or diffed in this conversation; with none, one line: `Which one? Reply "reviewed R-12", or "reviewed all today".` Several ids (`reviewed R-3 R-4`) → one block per id, in one Bash call.

  <!-- test-anchor: desk-reviewed -->

  ```bash
  "$HQ" review R-2; echo "exit=$?"
  ```

  `exit=0` → one line: `R-2 reviewed.` (reviewing a reviewed item again changes nothing and says the same). `exit=4` → `R-2: no such Review.` (or its stderr line).
- `reviewed all today` → every Review synced today (America/New_York, the "Today" groups of the view) that is still unreviewed, in one transaction:

  <!-- test-anchor: desk-reviewed-today -->

  ```bash
  "$HQ" review --synced-today; echo "exit=$?"
  ```

  It prints the ids it marked, one per line. Reply in one line: `Marked 3 reviewed: R-12, R-13, R-14.`, or with none, `Nothing synced today is waiting.` Flagged items keep their flag (their follow-up is still open), and an item synced on an earlier day stays in the view.

## `flag R-<n> "what to follow up"`

The note is the operator's words: one line, at most 200 characters (longer → ask for a shorter one in one line, store nothing). It goes through a quoted here-document, never inside the command's quotes:

<!-- test-anchor: desk-flag -->

```bash
NOTE_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-flag.XXXXXX")
cat > "$NOTE_FILE" <<'DESK_NOTE'
<the note, verbatim, without its surrounding quotes>
DESK_NOTE
"$HQ" flag R-2 --note "$(cat "$NOTE_FILE")"; rc=$?; rm -f "$NOTE_FILE"; echo "exit=$rc"
```

- `exit=0` → one line: `R-2 flagged: "<the note>". Reply "follow up R-2" to file it as an issue in <repo>.` The item leaves the unreviewed view (a flag is a reading); `reviewed R-2` clears the flag once the follow-up is handled.
- `exit=4` → its stderr line (no such Review, a note on two lines, an over-long note). `exit=5` → `That note looks like it holds a credential — not stored. Reword it without the secret.`

## `follow up R-<n>`: the flag becomes an issue

Only for a flagged Review, and only when the operator types it: filing is a write to GitHub. The issue goes to **the item's own repository**, never the current checkout's. This is a one-shot filing, not `/issue-maker`'s capture mode (`desk/DESIGN.md` 4.2.5).

### 1. Check first

<!-- test-anchor: desk-follow-up-check -->

```bash
SHOWN=$("$HQ" show R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  printf '%s\n' "$SHOWN" | jq -r '"status=\(.item.status)", "repo=\(.item.repo)", "link=\(.item.context[0] // "")",
    "note=\([.events[] | select(.kind == "flagged")] | last | .note // "")",
    ([.events[] | select(.kind == "commented" and ((.note // "") | startswith("follow-up: ")))] as $fu
     | ($fu[] | select(.note != "follow-up: filing") | "filed=\(.note[11:])"),
       (if ($fu | last | .note) == "follow-up: filing" then "pending=yes" else empty end))'
fi
```

- `status` is not `flagged` → `R-2 isn't flagged — flag it first: flag R-2 "what to follow up".` and stop.
- A `filed=` line → a follow-up was already filed: `R-2's follow-up is already filed: <url>.` and stop.
- `pending=yes` (step 3 started filing and never recorded an issue: interrupted, or GitHub's answer held no issue URL) → the issue may exist already, so never file blind: `R-2's follow-up was started but never recorded, so it may already be filed in <repo>. Check its issues for one linking <link>; reply "follow up R-2 again" to file it anyway.` and stop. Only `follow up R-<n> again` goes past this line, and only this line: every other check above still applies.

### 2. Draft the issue

From the item (its title, `link`, and `repo`) and the flag's `note`, in `/issue-maker`'s seven-section body: `## Background` (what landed, with its link), `## Problem` (the note, in the operator's words first), `## Proposed solution`, `## Acceptance Criteria` (numbered `4.1 [ ]` items), `## Test Plan` (`5.1 [ ]`), `## Notes / Open questions`, and `## Related Issues` (the source PR or issue), ending with the line `_Captured via /issue-maker._`, so the next sync brings it back as a Review to check (`desk/DESIGN.md` 2.7). The title is at most 70 characters and says what to fix, not that something was flagged. Say only what the note and the item support.

### 3. File it and record it

<!-- test-anchor: desk-follow-up -->

```bash
ITEM=$("$HQ" get R-2 --json); rc=$?
if [ "$rc" -ne 0 ]; then echo "exit=$rc"; else
  REPO=$(printf '%s\n' "$ITEM" | jq -r .repo)
  GH=""
  for c in "${HUMAN_QUEUE_GH:-}" /opt/homebrew/bin/gh "$(command -v gh 2>/dev/null)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then GH="$c"; break; fi
  done
  TITLE_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-issue-title.XXXXXX")
  BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-issue-body.XXXXXX")
  cat > "$TITLE_FILE" <<'DESK_TITLE'
<the title>
DESK_TITLE
  cat > "$BODY_FILE" <<'DESK_BODY'
<the body>
DESK_BODY
  if [ -z "$GH" ]; then echo "exit=gh-missing"; else
    "$HQ" comment R-2 "follow-up: filing" >/dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then echo "mark-exit=$rc"; else
      CREATED=$("$GH" issue create --repo "$REPO" --title "$(cat "$TITLE_FILE")" --body-file "$BODY_FILE" </dev/null); rc=$?
      URL=$(printf '%s\n' "$CREATED" | tail -n 1)
      echo "create-exit=$rc url=$URL"
      if [ "$rc" -eq 0 ]; then
        case "$URL" in
          https://github.com/*/issues/[0-9]*) "$HQ" comment R-2 "follow-up: $URL"; echo "comment-exit=$?" ;;
        esac
      fi
    fi
  fi
  rm -f "$TITLE_FILE" "$BODY_FILE"
fi
```

The issue body is the text most likely to hold a delimiter-shaped line: check it against `DESK_BODY`, and the title against `DESK_TITLE`, before running the block ("Rules for every verb").

The `follow-up: filing` comment is written **before** the issue is created, so a filing that never gets its URL recorded (the block interrupted, or GitHub's answer holding no issue URL) leaves R-2 marked, and step 1 stops the next `follow up R-2` instead of filing a second issue.

- `create-exit=0` with an issue URL and `comment-exit=0` → the URL as the closing line: `Filed: <url>`. The comment puts the link in R-2's history (`show R-2`), which is how step 1 knows it was filed.
- Created but `comment-exit` is not 0 (or missing) → `Filed: <url> — but the store didn't record it on R-2; run: comment R-2 "follow-up: <url>"` with the exact command. Never say it is recorded when it is not.
- `create-exit` not 0, or no issue URL → one line naming it. R-2 stays marked as filing, because GitHub may have created the issue anyway: say `R-2 is marked as filing; check <repo>'s issues before "follow up R-2 again".`
- `exit=gh-missing`, or `mark-exit=<n>` (the CLI's own stderr line says why; `7` is the store-unreachable line above) → one line naming it; nothing was filed and nothing recorded.
