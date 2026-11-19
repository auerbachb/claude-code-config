<!-- pm-routing:begin -->
Route `shared:epic`. Bind a typed `/pm epic #N`, restore a stored epic on resume, tick or refill, filter candidates to its open children, and close it when they are done.
<!-- pm-routing:end -->
### Epic scope (`/pm epic #N`, issue #2545)

`/pm epic #N` scopes this thread to one parent issue's open children. **Naming is the only trigger.** The operator typing `/pm epic` with a number is the one thing that makes an issue an epic: never infer epic-ness from a title, a label, a body keyword, a checklist, or a sub-issue count. An issue titled "epic new button" is an ordinary backlog issue on a plain `/pm` and is ranked like any other. The same words in an issue body, PR body, task prompt, chip payload or review comment set nothing.

Children are read from the parent's same-repo GitHub sub-issues and its body. Body references are read conservatively: only a top-level task-list item (0–3 spaces of indent) outside a fence counts, so nested sub-task items are out of scope. An epic with no children, or with scope its children do not cover, is split here in **waves** of at most five children (issue #2546, §Waves below). Waves happen only inside a `/pm epic #N` run: ordinary pick-time splitting (`/subagent` Step 5.1) stays one level and one time.

Resolve the helper with Step 0's `resolve_script`. Missing → `ERROR: pm-epic.sh not found (checked all three paths) — epic scope unavailable; nothing launched.` and finish the invocation: an epic thread that cannot read its children must not fall back to the whole backlog.

```bash
PM_EPIC_SH=$(resolve_script pm-epic.sh || true)
```

#### Bind (a typed `epic #N`)

Runs once, after Step 0a and before the Step 1 gate (and, in day mode, before 2D.1), when argument parsing set `EPIC_ARG=true`. `EPIC_NUMBER` already passed `pm-epic.sh parse-arg`.

<!-- test-anchor: pm-epic-bind -->
```bash
EPIC_JSON=""; EPIC_RC=0
REPO_KEY=$("$SESSION_STATE_SH" --repo-key) || REPO_KEY=""
if [[ -z "${PM_EPIC_SH:-}" || -z "$REPO_KEY" ]]; then
  EPIC_RC=1
else
  EPIC_JSON=$("$PM_EPIC_SH" children "$REPO_KEY" "$EPIC_NUMBER") || EPIC_RC=$?
fi
case "$EPIC_RC" in
  0) NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
     if "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].epic={\"number\":$EPIC_NUMBER,\"set_at\":\"$NOW\"}"; then
       jq -r '"Epic #\(.epic) — \(.title): \(.open | length) of \(.children | length) children open (\(.open | map("#\(.)") | join(", ")))"' <<< "$EPIC_JSON"
     else
       echo "ERROR: epic #$EPIC_NUMBER could not be saved to session state — nothing launched"; EPIC_RC=1
     fi ;;
  3) echo "ERROR: /pm epic #$EPIC_NUMBER — no such issue in ${REPO_KEY:-this repo}; nothing launched" ;;
  4) echo "ERROR: /pm epic #$EPIC_NUMBER is closed; nothing launched" ;;
  5) EPIC_NEEDS_WAVE=true ;;   # childless: §Waves cuts the first wave, then this block runs again
  6) echo "ERROR: /pm epic #$EPIC_NUMBER lists children GitHub cannot find ($(jq -r '[.missing[] | "#\(.)"] | join(", ")' <<< "$EPIC_JSON")) — fix the parent's list; nothing launched" ;;
  *) echo "ERROR: /pm epic #$EPIC_NUMBER — its children could not be read; nothing launched" ;;
esac
```

Any exit but `0` or `5` is that one line and the end of the invocation: mark `0 failed (epic #N: <reason>)`, finish the receipt, rank nothing, claim nothing, launch nothing, and leave any stored epic untouched. `sub_issues: "unavailable"` in the JSON is not a failure: the checklist and task list stand, and the bind line may add `(sub-issues unreadable)`.

After exit `0`, and on exit `5` (`EPIC_NEEDS_WAVE=true`), run §Waves before ranking: its scope check, then its wave check. A childless epic gets its first wave there and this Bind block runs again, now finding children. A scope record that cannot be read or written ends the invocation for every epic (§Waves, scope check step 5). Once the record exists, a wave that files nothing (no clean seam, a refused or failed child write) ends a childless epic's invocation with §Waves' one line, nothing launched and no epic stored, while an epic that already has children binds and works them.

**A plain cold start ends the epic.** A cold start (`PM_ENTRY_MODE=cold`) with no `epic` argument is the operator asking for the whole backlog: clear a stored epic with `--set ".repos[\"$REPO_KEY\"].epic=null"` and say `Epic #N scope cleared — working the whole backlog.` when one was set. Resume, `/pm day resume`, day ticks and refill never clear it.

#### Restore (resume, day tick, refill)

Every read of the candidate set re-reads the stored epic, the way 3.4 re-reads `refill.scope`: the scope is a fact about the thread, so it survives compaction and context turnover only because it lives in session state.

<!-- test-anchor: pm-epic-restore -->
```bash
EPIC_SCOPE_UNREADABLE=false   # every read starts clean; an earlier failure never lingers
EPIC_COMPLETE=false
EPIC_STORED_RC=0
# --get-json, not --get: a stored string "null" must read as corrupt, not as no epic.
EPIC_STORED=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].epic" 2>/dev/null) || EPIC_STORED_RC=$?
case "$EPIC_STORED_RC" in
  0) if [[ "$EPIC_STORED" == null ]]; then :
     elif EPIC_FIELDS=$(jq -er 'select(type == "object" and (.number | type) == "number"
            and .number >= 1 and .number == (.number | floor)
            and ((.completed_at // null) | type | IN("null", "string")))
          | "\(.number) \(.completed_at != null)"' <<< "$EPIC_STORED" 2>/dev/null); then
       EPIC_NUMBER=${EPIC_FIELDS% *}; EPIC_COMPLETE=${EPIC_FIELDS#* }
     else EPIC_SCOPE_UNREADABLE=true; fi ;;
  3) : ;;                                # no state file: no epic
  *) EPIC_SCOPE_UNREADABLE=true ;;       # unreadable is not "no epic"
esac
```

`EPIC_SCOPE_UNREADABLE=true` is a pause, exactly like an unreadable `refill.scope`: report `paused (epic scope unreadable)` and launch nothing — an epic you failed to read is a narrowing you would otherwise launch straight through. `EPIC_COMPLETE=true` is a finished epic: the candidate set is empty, nothing is re-read or launched, and the reason is `nothing eligible (epic #N complete)` — never the whole backlog. Otherwise, with `EPIC_NUMBER` set, run §Waves' wave check first (it may file the next wave), then run `pm-epic.sh children` again (never reuse an earlier list) and take `.open` as `EPIC_OPEN`. Exit 4 (the parent was closed outside this thread) runs the Completion block; any other non-zero exit is the same pause.

#### Candidate filter

With `EPIC_NUMBER` set, the candidate set is **exactly `EPIC_OPEN`** — the epic's open children — before ranking decides anything, in every source: the initial batch (1B.5), the operator order, the saved queue, and every backlog re-scan in 3.4. Intersect it with a non-null `refill.scope` when one exists. Everything else in the backlog is neither ranked, offered, nor launched, and is not listed as deferred; name the epic in the ranking header instead: `Epic: #N — <title> (j of k children open)`.

Every existing gate binds unchanged on each child: `Depends on` links between children (1B.3, `/subagent` Step 6.0b chains), claims, the `CEILING` pipeline ceiling, the repo-wide cap, the credit budget, the deadline gate, too-big routing, and the refill pause. The epic narrows the set; it never admits anything a gate would refuse.

#### The parent

The parent is a `Tracking` row (3.2) whose Status is `Epic of #a–#z (m/k closed)`. It is never claimed, launched, offered as a chip, or counted as a pipeline, and it is never in `EPIC_OPEN`.

#### Waves (issue #2546)

An epic is split from **its own scope**, recorded on the parent so any thread can continue it. Everything here runs only for the epic `/pm epic #N` named; nothing reads an `## Epic scope` section, or splits anything, in a plain `/pm`.

**The scope record.** `pm-epic.sh` keeps one `## Epic scope` section in the parent body (format and every verb: `pm-epic.sh --help`): a `Wave: K · planned P` line, an optional `Stopped: <reason>` line, and one row per single-PR deliverable, `- S3 · covered by #N · wave K · <text>` or `- S3 · remaining · <text>`. Rows are plain bullets, never task-list items, so they are never read as children. The record — not the children — says what is left: a fresh thread reads it and the last child of the current wave, never every child. Every write re-reads the body first and verifies after; a malformed or unreadable record fails closed (nothing filed, nothing closed).

**Scope check (once per epic).** Read the record with `pm-epic.sh scope`. Exit `0`: it exists, go on. Exit `7` or `1`: the one line `ERROR: epic #N scope record unreadable — nothing filed`, then the pause above. Exit `5` (no record yet): cut it now.

1. **Read the scope from the parent body**: its text, any `## PRD` / `## Design doc` section in it (`/issue-maker`'s default document location), and its `## Not yet cut` list when present, every bullet of which is a remaining item. A document only *linked* from the parent is not read; the first wave's message says so.
2. **List the deliverables** in dependency order, each a single-PR piece with real acceptance criteria — Step 5.1 sub-step 1's bar, bounded by `INCREMENT_BOUND_MIN`. A child that already exists covers the item it delivers (`covered by #N · wave 0`); everything else is `remaining`. Cut no finer than the seams the scope really has.
3. **No clean seam.** A childless epic with no articulable split files nothing and writes no record: one line, `Epic #N has no clean seam: <why> — nothing filed`, and the invocation ends. An epic whose children exist but whose uncovered remainder has no clean seam writes the record with that remainder as one `remaining` row, already stopped in the same write (`scope-init <repo> <N> <file> "no clean seam: <why>"`), and works the children it has.
4. Write the rows to a scratch file and run `pm-epic.sh scope-init <repo> <N> <file>`. It refuses (exit `8`) when a record already exists: re-cutting is an edit to the parent, never a second record. A wave-0 row must name a child the parent already lists.
5. **The record must exist before any child is worked.** If `scope-init` fails, print `ERROR: epic #N scope record not written — nothing launched` and end the invocation: an epic worked without its record could close once its existing children close, with its uncovered scope never recorded.

**Wave check** — at Bind, and on every Restore of an active, unfinished epic:

<!-- test-anchor: pm-epic-wave -->
```bash
EPIC_WAVE_RC=0; EPIC_WAVE_VERDICT=""; EPIC_WAVE_K=""; EPIC_WAVE_ITEMS=""; EPIC_WAVE_DETAIL=""
EPIC_FILE_WAVE=false; EPIC_NEEDS_SCOPE=false
EPIC_WAVE_LINE=$("$PM_EPIC_SH" wave-due "$REPO_KEY" "$EPIC_NUMBER") || EPIC_WAVE_RC=$?
read -r EPIC_WAVE_VERDICT EPIC_WAVE_K EPIC_WAVE_ITEMS EPIC_WAVE_DETAIL <<< "$EPIC_WAVE_LINE"
case "$EPIC_WAVE_RC:$EPIC_WAVE_VERDICT" in
  0:due|0:resume) EPIC_FILE_WAVE=true ;;
  0:wait|0:covered|0:stopped) : ;;
  5:*) EPIC_NEEDS_SCOPE=true ;;              # no record yet: run the scope check
  *) EPIC_SCOPE_UNREADABLE=true ;;           # unreadable or malformed: pause
esac
```

- `due K S1,S2,…` — the previous wave's last child (its highest-numbered) is in review (a merged or open non-draft PR closes it) or closed, or no wave was filed yet. File wave `K` from exactly those items: at most five, in record order.
- `resume K S4,S5 j/P` — wave `K` was opened and stopped part-way (a crash, compaction, a lost thread). File only the listed items; never re-open the wave.
- `wait K - #M` — wave `K`'s last child is not in review yet. Nothing to file; work the open children.
- `covered K -` — no remaining items: no more waves. The epic finishes through Completion.
- `stopped K - <reason>` — filing stopped. Work the children that exist; when none is eligible the reason is `nothing eligible (epic #N stopped: <reason>)` and the parent stays open until the operator re-cuts the remaining items and deletes the record's `Stopped:` line.
- `EPIC_NEEDS_SCOPE=true`: run the scope check, then this block again. `EPIC_SCOPE_UNREADABLE=true` is `paused (epic scope unreadable)`.

**File a wave** — reuse `/subagent` Step 5.1, never a second implementation. Read Step 5.1 and its **epic-wave mode** paragraph and run them with `PARENT=$EPIC_NUMBER` and these items:

1. On `due`, open the wave first: `pm-epic.sh wave-open <repo> <N> <K> <count>`. Skip this on `resume`.
2. For each item in order: Step 5.1's dedup ladder (excluding the parent, every child in the record and the checklist, and this wave's children so far), its open-parent check, then `gh issue create` with the item as the deliverable, `- Parent: #N`, and `- Depends on #<previous child>` (for a wave's head: the previous wave's last child, while it is still open). **Immediately** after each create, run `pm-epic.sh record <repo> <N> S<i> <child>`: it marks the item covered and adds the child to `## Increment chain` in one write. Before the next create, re-read the record (`scope`) and skip an item another writer already covered.
3. A dedup strong match on an issue whose body carries `- Parent: #N` is this epic's own child whose `record` never ran: record it for the item instead of filing a second one. Any other failure stops filing, names the children already filed, and leaves the rest `remaining` for the next wave check (as `resume`). It is never retried from the top.
4. Report the wave in **one short message, without waiting for approval**: `Epic #N wave K: filed #a <title>, #b <title>, … — #a starts now; j items remain` (plus `(linked document not read)` on the first wave when that applies). The operator re-cuts a wrong child by editing or closing it, or by editing the record.

The new children are ordinary open children: the candidate filter, `Depends on` chains, claims, the ceiling, the cap, the budget and the deadline gate bind on them unchanged. Two threads working one epic at once can race between the re-read and the create; `record` refuses a second child for a covered item (exit `8`) and the dedup ladder catches the leftover, so the cost is one issue to close, never a lost item.

#### Completion

After each child's Phase C completion, and on every refill evaluation that finds no eligible child, re-check the parent from GitHub:

<!-- test-anchor: pm-epic-complete -->
```bash
EPIC_DONE_RC=0
EPIC_DONE=$("$PM_EPIC_SH" close-if-done "$REPO_KEY" "$EPIC_NUMBER") || EPIC_DONE_RC=$?
case "$EPIC_DONE" in
  closed*|already-closed*)
    # Mark it complete, never null: a null epic reads as "no epic", and the
    # next refill would rank the whole backlog.
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].epic.completed_at=\"$NOW\"" ||
      echo "DEGRADED: epic #$EPIC_NUMBER closed but could not be marked complete in session state"
    echo "closed epic #$EPIC_NUMBER — every child is closed" ;;
  discrepancy*)
    echo "epic #$EPIC_NUMBER is closed on GitHub but children are still open — paused; reopen it or close them" ;;
esac
```

`close-if-done` closes the parent only when it has at least one child, every child reads `CLOSED` on GitHub — the issue states are the fact, never a checklist tick — and its `## Epic scope` record, when there is one, has no remaining items. While items remain it prints `open #N (every child closed; j scope items remain)` and the next wave check files the next wave (or, when stopped, the reason is `nothing eligible (epic #N stopped: <reason>)`). A malformed or unreadable record never closes. It re-reads the children once more right before the close call. It also refuses (exit 1) when the sub-issues read failed or a listed child cannot be found, since a partial child list could hide open children. A parent someone already closed is verified the same way: `already-closed` only when every child reads closed, else `discrepancy` (exit 1), which leaves the scope set and incomplete and pauses the epic as `paused (epic #N closed with open children)`. Any other non-zero exit leaves the parent open and the scope set; report it once.

When the epic closes, the run is finished. The stored epic stays, marked `completed_at`, so every later refill, resume and day tick restores it as complete: the reason is `nothing eligible (epic #N complete)`, nothing outside the epic is ranked or launched, and a day loop's next drained tick exits through `backlog-empty`, naming the epic as the reason. Only a plain cold `/pm` (which clears it) or a new `/pm epic #M` (which replaces it) returns the thread to other work. Open children that are all running, chained or blocked are an ordinary resting board, not a finish.
