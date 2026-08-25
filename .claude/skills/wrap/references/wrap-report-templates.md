# `/wrap` Step 4.3 — Verbose Report Template

Referenced from `wrap/SKILL.md` Step 4.3. The SKILL.md keeps the silent-default rules, the `## Wrapped up` block, the blocker path strings, and the selector logic; this file holds the full verbose template and its rendering rules. Nothing here prints on the silent default (issue #851) — it renders only under `--verbose` or on an explicit request.

## Verbose report (`--verbose`, or on explicit request)

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Main quarantine** {QUARANTINE_STATUS from Step 2.5 — e.g. "clean", "quarantined: recovery/dirty-main-20260424-003012 (uncommitted)", or "no-op: main is clean"}
- **Main branch** {MAIN_SYNC_STATUS from Step 2.5 — e.g. "reset abc1234 → def5678", "up to date (abc1234)", "aborted: local main has 1 unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running", or "failed: ..."}
- **Follow-ups:** {skipped-as-duplicate items and any creation failures from Part A, or "No follow-up items detected." — filed issues are listed under "Issues filed" below, not here}

## Issues filed

- [#{number}](https://github.com/{owner}/{repo}/issues/{number}) — {title} — {rationale}
- [#{number}](https://github.com/{owner}/{repo}/issues/{number}) — {title} — {rationale}

{One line per WRAP_FILED_ISSUES entry, Part A and Part B together. Omit the whole section only when the registry is empty.}

## Filings suppressed as duplicates

- Appended to [#{N}](https://github.com/{owner}/{repo}/issues/{N}) instead of filing — "{finding summary}"
- Collapsed into [#{N}](https://github.com/{owner}/{repo}/issues/{N}) (filed earlier this run) — "{finding summary}"

{One line per suppressed filing, from Part A's Step 3.3 and Part B's Step 3.7 Stage 1/Stage 2 strong-match branches. Omit the whole section only when nothing was suppressed. A suppressed filing that does not appear here is indistinguishable from a finding that was silently dropped — see .claude/reference/autofile-dedup.md.}

## Session sweep

### Auto-handled
- {one bullet per SWEEP_AUTO_HANDLED entry — stopped Monitor tasks, deleted handoffs, auto-filed tickets, and the single churn-hotspot aggregate; omit the section if empty}

### Needs your decision
- {one bullet per SWEEP_NEEDS_DECISION entry — proposed tickets, surfaced crons/subagents, PM-hygiene drift, time-sensitive reminders, future-self handoff; omit the section if empty}

### Verdict
{exactly one of: `Clear to archive`  |  `N items pending your decision before archive` — from Step 3.13; never improvise}

---

- **Lessons:** {summary or "clean session" — recap of Step 4.2}
```

## Rendering rules (verbose)

- Cap **Auto-handled** and **Needs your decision** at **3–5 bullets** each; if more, show the top items and summarize the remainder as one bullet: "+ N more — see `.prs["$PR_NUMBER"].wrap_sweep` in session-state". **Auto-filed tickets are exempt from this cap** — every created issue's title + body is surfaced in full.
- Render the churn-hotspot suppression as its one aggregate `SWEEP_AUTO_HANDLED` entry; never expand `suppressed_set` into per-file bullets. The aggregate names total hotspots, conflict-cost hotspots, surfaced decisions, and suppressed closed/no-cost hotspots, so suppression stays auditable without recreating the decision flood fixed by Issue #1307.
- The **Issues filed** section is never capped or truncated. One line per issue, each a clickable link with number, title, and one-line rationale.
- The **Filings suppressed as duplicates** section is likewise never capped. Every finding the dedup check kept out of a new issue must name the issue it deferred to.
- Omit an empty subsection rather than printing "none".
- The **Verdict** line is mandatory and is one of the two canonical strings only.
- If Part B was skipped (e.g. Phase C subagent with narrow transcript and no state findings), still print `### Verdict` → `Clear to archive`.
