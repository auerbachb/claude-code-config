# Create: read a finished set back for gaps and overlaps

> Load only for: `create:postfile` Step 9b2 printed `COHERENCE=run` — the last member of a chain, or of a batch of three or more, is recorded
> Prerequisites: session state loaded; every member recorded with the set's `set_id`; the Step 9c offer and the closing table not yet printed

Each issue was reflected on alone as it was written. This pass reads the **finished set as a whole**, once, against what it was cut from — the original ask, or the source document when there is one — and reports what no single issue could show: a requirement nothing covers, a requirement two issues both claim, an order that does not match what depends on what, and boundary lines that disagree with their neighbours. It asks nothing and pauses nothing; it runs in both modes.

## Begin — never twice

<!-- test-anchor: issue-maker-coherence-begin -->
```bash
: "${SET_ID:?restore the set id Step 9b2 printed}"
if jq -e --arg id "$SET_ID" --arg repo "$REPO" 'any((.coherence_runs // [])[]; .set_id == $id and .repository == $repo and .status == "done")' "$LOG" >/dev/null; then
  echo "COHERENCE=done — reprint the stored report only:"
  jq -r --arg id "$SET_ID" --arg repo "$REPO" '[(.coherence_runs // [])[] | select(.set_id == $id and .repository == $repo and .status == "done")][-1].report[]' "$LOG"
  exit 0
fi
set_log 'if .active_set == null or .active_set.set_id != $id or .active_set.repository != $repo then error("coherence set is not the open set")
  else .active_set.review = (.active_set.review // {status:"pending", started_at:$ts}) end' \
  --arg id "$SET_ID" --arg repo "$REPO" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" || exit 1
jq -c --arg id "$SET_ID" --arg repo "$REPO" "$MINE_DEF"'{source:.active_set.source, applied_fixes:(.active_set.applied_fixes // []),
  members:[.issues[] | select(same_repo and .set_id == $id) | {number, chain}]}' "$LOG"
```

`COHERENCE=done` means a recovered session already ran this pass: reprint its stored lines only if the Step 9c offer and the closing table are still pending, and change nothing. A `pending` review left by an interrupted run is simply run again — the reads are safe to repeat, and fixes already listed in `applied_fixes` are not applied twice.

## Read the set from GitHub, not from memory

Fetch every member, in filing order, and the source:

```bash
gh issue view "$N" --repo "$REPO" --json number,title,body,state
```

- **Members** are the rows printed above. Read their titles and bodies from this fetch only — never from drafts still in context, which may predate a rename, a dedup edit, or a checklist write. A member closed since filing is left out of the checks and named in the report.
- **Source.** With no `source.ref`, the source is `source.ask`, the original ask text stored when the set opened. With a `source.ref` from `create:doc-gate`, read the document there: the tracking parent's `## PRD` / `## Design doc` section through the same `gh issue view`, a repo path with `git show origin/<default>:<path>`, or a shared doc with the docs tool that wrote it. A document that cannot be read falls back to `source.ask`, and the report says so.
- **Tracking parent.** A row whose `chain.role` is `"parent"` is read as the document holder and checklist, not as a slice: its `## Increment chain` list should name every child, and anything under its `## Not yet cut` is deferred on purpose, never a gap.

A member fetch that fails stops the checks: report the one line `Coherence pass could not read #N (<reason>) — set not checked`, and finish below with that line. Never retry in a loop.

## The four checks

Split the source into its concrete requirements first — a PRD's `R1`, `R2`, …; otherwise each distinct thing the ask says must exist or happen. A requirement **lands** in an issue only when a specific acceptance criterion or body sentence in it can be quoted for it; a theme word in a title does not count.

1. **Coverage** — every requirement lands in some member. A requirement that lands nowhere is a **gap**.
2. **Overlap** — no requirement lands in two members' acceptance criteria. Context in one and AC in another is not an overlap.
3. **Order** — `Depends on #N` lines (case-insensitive, in `## Related Issues`) match what actually depends on what: each chain increment depends on its immediate predecessor and nothing later; an issue whose AC consumes something another member delivers depends on that member and is filed after it; each child of a tracking parent carries `- Parent: #<parent>` and never `Depends on` the parent.
4. **Boundaries** — each increment's boundary line agrees with its neighbours: what a non-final increment defers is what the next one delivers; only the last increment uses the final form; titles carry `{i}/{n}` matching their positions.

## Fix only what is clear

A **clear fix** is mechanical and leaves what gets built unchanged:

- a missing or wrong `Depends on #<predecessor>` line between neighbouring chain increments;
- a missing `- Parent: #<parent>` line on a child;
- a boundary line in the wrong form (final versus non-final) whose named content stays the same;
- an `{i}/{n}` title marker that does not match the position.

Apply each through `update:edit` — resolve and load it only now, and only when a clear fix exists — under its "Coherence-pass fixes" rule: the finding stands in for the confirmation, while the freshness check, the verification and the log update still run. After each verified write, record it so a recovered run skips it:

<!-- test-anchor: issue-maker-coherence-fix-receipt -->
```bash
set_log 'if .active_set.set_id != $id then error("coherence set changed") else
  .active_set.applied_fixes = ((.active_set.applied_fixes // []) | if index([($n|tonumber)]) then . else . + [($n|tonumber)] end) end' \
  --arg id "$SET_ID" --arg n "$N" || exit 1
```

Everything else is **reported, never applied**: a gap, an overlap, a reorder, a new dependency between batch issues, a boundary whose deferred work no later member picks up, any change to scope or estimate. A gap is never filed as a new issue here — name it and let the user decide. A fix the freshness check refuses becomes a reported finding too.

## Report — one to five lines, before the offer

- **Clean:** one line — `Coherence pass: read #a–#d back against <the ask | <document>> — no gaps, overlaps, or order problems.`
- **Findings (default mode):** at most five lines. Each applied fix is a decision point naming the issue and what changed (`Fixed #c: Depends on #b, not #a`). Each finding that needs a call names the issues and the next step (`Gap: the ask's CSV export lands in no issue — /update #d or file it`; `Overlap: #b and #c both deliver the login form — /update one of them`). Merge findings of one kind onto one line when there are more than fit.
- **Rapid-fire:** one line of counts — `Coherence pass: 1 gap, 0 overlaps, 0 order, 1 boundary; 1 fixed (#c).` — or the clean line.

Print the lines, then finish. The Step 9c offer and the closing table follow; nothing of this pass goes between the table and the closing link.

## Finish — record that the pass ran

Set `REPORT_LINES` to the printed lines, one per line, then write the receipt and close the set in one mutation. A failed write stops before the offer, with the set still open, so recovery runs the pass again rather than skipping it.

<!-- test-anchor: issue-maker-coherence-finish -->
```bash
: "${REPORT_LINES:?set the report lines that were printed}"
REPORT_JSON=$(printf '%s\n' "$REPORT_LINES" | jq -R . | jq -sc 'map(select(length>0))') || exit 1
set_log 'if .active_set == null or .active_set.set_id != $id or .active_set.repository != $repo then error("coherence set is not the open set") else
  .coherence_runs = ((.coherence_runs // []) + [{set_id:$id, repository:$repo, status:"done", completed_at:$ts,
    report:$report, applied_fixes:(.active_set.applied_fixes // []), source:(.active_set.source.ref // "ask")}])
  | .active_set = null end' \
  --arg id "$SET_ID" --arg repo "$REPO" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson report "$REPORT_JSON" || exit 1
```

Return to `create:postfile` Step 9c.
