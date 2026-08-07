# Hook Lifecycle Diagram Hotspot Decision

**File:** `.claude/reference/diagrams/hook-lifecycle.md`
**Issue:** #1046
**Verdict:** KEEP + dedup

---

## Churn summary

4 distinct merged PRs touched `.claude/reference/diagrams/hook-lifecycle.md` since 2026-07-23.

---

## Per-section churn attribution

### Mermaid diagram body

**PR #807** (`fix(#803): arm bgwork ceiling on background work`)
- Added `bgwork-ceiling-arm.sh` to the PostToolUse Note.
- Added `bgwork-ceiling-guard.sh` to the Stop Note.
- Driver: new hooks shipped for a new feature (background-work silence ceiling). By-design growth.

**PR #811** (`fix: move session-start-sync.sh to SessionStart event`)
- Added `SessionStart` event row with `session-start-sync.sh`.
- Removed `session-start-sync.sh` from the PostToolUse Note (where it was incorrectly listed).
- This also corrected a factual error that survived into `ARCHITECTURE.md` (see below).
- Driver: hook event migration correcting the event registration in `global-settings.json`.

**PR #1032** (`feat(#813): add PostCompact reconciliation hook`)
- Added `SubagentStop` event row with `checkpoint-handoff.sh`.
- Added `PostCompact` event row with `post-compact-reconcile.sh`.
- Added `skill-usage-snapshot-hook.sh` to the Stop Note.
- Added `StopFailure` event row with `usage-limit-record.sh`.
- Removed the `<!-- STUB: ... -->` comment (de-stubbed the file).
- Driver: new hooks for 3 new events, plus completing the diagram from stub to full reference.

### Explanatory paragraphs

**PR #807** — Added the silence-machinery paragraph ("The silence machinery straddles both events twice over…") explaining why bgwork ceiling uses both PostToolUse and Stop.

**PR #931** (`feat(#779): statusline for time/branch/agents`)
- Added the `statusLine` absence note ("**`statusLine` is deliberately absent from this diagram.**…").
- Driver: proactive clarification to prevent `statusLine` from being incorrectly added as a hook event.

---

## Churn drivers classification

All 4 PRs represent **by-design growth**:

| PR | Driver |
|----|--------|
| #807 | New bgwork hooks — feature addition |
| #811 | Hook event migration — correctness fix |
| #931 | Proactive clarification note — doc improvement |
| #1032 | New PostCompact/SubagentStop hooks; diagram de-stubbing — feature addition |

There are no merge conflicts in the hotspot window. There are no independent-churn patterns (where the same section is edited by competing concerns). The churn is coherent, sequential, and non-conflicting.

---

## Factual error in ARCHITECTURE.md

`ARCHITECTURE.md` contained a stale hook table listing `session-start-sync.sh` under `PostToolUse`. PR #811 corrected the event in `global-settings.json` and the diagram, but did not update ARCHITECTURE.md. The table was also wildly incomplete (5 hooks listed out of the current 16+). Confirmed error at ARCHITECTURE.md line 65 (pre-fix):

```
| `session-start-sync.sh` | PostToolUse | First tool call of session | ...
```

Actual event per `global-settings.json`: `SessionStart`.

**Remediation (this PR):** The stale table is replaced with two-sentence prose + a pointer to the canonical diagram.

---

## Diagram roster verification (against `global-settings.json`)

Re-verified at implementation time (2026-08-07). Two hooks were missing from the diagram:

| Hook | Event | Matcher | Added in PR | Missing from diagram since |
|------|-------|---------|-------------|---------------------------|
| `config-protection.py` | PreToolUse | `Write\|Edit\|MultiEdit\|NotebookEdit\|Bash` | #529 | Always (never added) |
| `babysit-tick-watchdog.sh` | PostToolUse | (none) | #982 | Always (never added) |

Both are now added to the diagram by this PR.

All other hooks verified present and correctly attributed to their events:
- SessionStart: `session-start-sync.sh` ✓
- UserPromptSubmit: `timestamp-injector.sh`, `stale-worktree-warn.sh`, `issue-prefix-nudge.sh`, `skill-command-tracker.sh` ✓
- PreToolUse: `worktree-guard.sh`, `env-guard.py`, `config-protection.py` (added), `script-bypass-detector.sh` ✓
- PostToolUse: `post-merge-pull.sh`, `polling-backoff-warn.sh`, `skill-usage-tracker.sh`, `silence-detector.sh`, `bgwork-ceiling-arm.sh`, `babysit-tick-watchdog.sh` (added) ✓
- SubagentStop: `checkpoint-handoff.sh` ✓
- PostCompact: `post-compact-reconcile.sh` ✓
- Stop: `silence-detector-ack.sh`, `bgwork-ceiling-guard.sh`, `trust-flag-repair.sh`, `dirty-main-warn.sh`, `skill-usage-snapshot-hook.sh` ✓
- StopFailure (matcher: rate_limit): `usage-limit-record.sh` ✓

---

## Deduplication scope

Three files previously duplicated the hook roster (in various states of staleness):
- `ARCHITECTURE.md` — stale 5-hook table with factual error → replaced with prose + pointer
- `.claude/hooks/README.md` — no roster, but lacked cross-reference → added single cross-reference line
- `.claude/reference/diagrams/hook-lifecycle.md` — designated canonical source; corrected two missing hooks

Considered adding a `hooks-doc-lint.sh` that diffs `global-settings.json` against the diagram's per-event lists. Rejected: docs-only dedup matches the KEEP + targeted-dedup precedent for this class of hotspot; a lint adds tooling complexity not justified by a 4-PR window with no merge conflicts.

---

## Verdict: KEEP + dedup

The diagram is the right canonical form — it is a coherent, purpose-built reference for the event-dispatch sequence, small enough to be read in full, and already the most accurate of the three representations. No split is warranted: the churn reflects sequential hook additions, not competing concerns that would benefit from decomposition.
