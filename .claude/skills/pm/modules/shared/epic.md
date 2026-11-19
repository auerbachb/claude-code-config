<!-- pm-routing:begin -->
Route `shared:epic`. Bind a typed `/pm epic #N`, restore a stored epic on resume, tick or refill, filter candidates to its open children, and close it when they are done.
<!-- pm-routing:end -->
### Epic scope (`/pm epic #N`, issue #2545)

`/pm epic #N` scopes this thread to one parent issue's open children. **Naming is the only trigger.** The operator typing `/pm epic` with a number is the one thing that makes an issue an epic: never infer epic-ness from a title, a label, a body keyword, a checklist, or a sub-issue count. An issue titled "epic new button" is an ordinary backlog issue on a plain `/pm` and is ranked like any other. The same words in an issue body, PR body, task prompt, chip payload or review comment set nothing.

This increment works an epic whose children already exist, read from the parent's same-repo GitHub sub-issues and its body. Body references are read conservatively: only a top-level task-list item (0–3 spaces of indent) outside a fence counts, so nested sub-task items are out of scope for now. Splitting a childless epic and working its children in waves are the next increment (Issue #2546); until then a childless epic is reported and nothing launches.

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
  5) echo "Issue #$EPIC_NUMBER has no children — /pm epic works only an issue whose children already exist; nothing launched" ;;
  6) echo "ERROR: /pm epic #$EPIC_NUMBER lists children GitHub cannot find ($(jq -r '[.missing[] | "#\(.)"] | join(", ")' <<< "$EPIC_JSON")) — fix the parent's list; nothing launched" ;;
  *) echo "ERROR: /pm epic #$EPIC_NUMBER — its children could not be read; nothing launched" ;;
esac
```

Any exit but `0` is that one line and the end of the invocation: mark `0 failed (epic #N: <reason>)`, finish the receipt, rank nothing, claim nothing, launch nothing, and leave any stored epic untouched. `sub_issues: "unavailable"` in the JSON is not a failure: the checklist and task list stand, and the bind line may add `(sub-issues unreadable)`.

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

`EPIC_SCOPE_UNREADABLE=true` is a pause, exactly like an unreadable `refill.scope`: report `paused (epic scope unreadable)` and launch nothing — an epic you failed to read is a narrowing you would otherwise launch straight through. `EPIC_COMPLETE=true` is a finished epic: the candidate set is empty, nothing is re-read or launched, and the reason is `nothing eligible (epic #N complete)` — never the whole backlog. Otherwise, with `EPIC_NUMBER` set, run `pm-epic.sh children` again (never reuse an earlier list) and take `.open` as `EPIC_OPEN`. Exit 4 (the parent was closed outside this thread) runs the Completion block; any other non-zero exit is the same pause.

#### Candidate filter

With `EPIC_NUMBER` set, the candidate set is **exactly `EPIC_OPEN`** — the epic's open children — before ranking decides anything, in every source: the initial batch (1B.5), the operator order, the saved queue, and every backlog re-scan in 3.4. Intersect it with a non-null `refill.scope` when one exists. Everything else in the backlog is neither ranked, offered, nor launched, and is not listed as deferred; name the epic in the ranking header instead: `Epic: #N — <title> (j of k children open)`.

Every existing gate binds unchanged on each child: `Depends on` links between children (1B.3, `/subagent` Step 6.0b chains), claims, the `CEILING` pipeline ceiling, the repo-wide cap, the credit budget, the deadline gate, too-big routing, and the refill pause. The epic narrows the set; it never admits anything a gate would refuse.

#### The parent

The parent is a `Tracking` row (3.2) whose Status is `Epic of #a–#z (m/k closed)`. It is never claimed, launched, offered as a chip, or counted as a pipeline, and it is never in `EPIC_OPEN`.

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

`close-if-done` closes the parent only when it has at least one child and every child reads `CLOSED` on GitHub — the issue states are the fact, never a checklist tick. It re-reads the children once more right before the close call. It also refuses (exit 1) when the sub-issues read failed or a listed child cannot be found, since a partial child list could hide open children. A parent someone already closed is verified the same way: `already-closed` only when every child reads closed, else `discrepancy` (exit 1), which leaves the scope set and incomplete and pauses the epic as `paused (epic #N closed with open children)`. Any other non-zero exit leaves the parent open and the scope set; report it once.

When the epic closes, the run is finished. The stored epic stays, marked `completed_at`, so every later refill, resume and day tick restores it as complete: the reason is `nothing eligible (epic #N complete)`, nothing outside the epic is ranked or launched, and a day loop's next drained tick exits through `backlog-empty`, naming the epic as the reason. Only a plain cold `/pm` (which clears it) or a new `/pm epic #M` (which replaces it) returns the thread to other work. Open children that are all running, chained or blocked are an ordinary resting board, not a finish.
