# fixpr hotspot — diagnosis and extract-not-split decision

Reference for Issue #788 (`.claude/skills/fixpr/SKILL.md` churn hotspot). Not auto-loaded.

## The problem being read

`fixpr/SKILL.md` was touched by 17 distinct merged PRs (#536, #542, #543, #565, #578, #586, #612, #619, #658, #689, #690, #709, #719, #724, #739, #761, #763) — the highest-churn skill file in the repo when Issue #788 was filed.

The file is the shared recovery junction for the entire workflow. Every caller (`/wrap` Step 2.1, `/babysit-pr`, `phase-b-reviewer`, `phase-c-merger`) dispatches fixpr's Steps 0–7 contract unmodified; only `BABYSIT_SAFE_CONFLICT_MODE=1` / `TASK_TYPE` fork behavior inside the junction itself. This junction nature explains part of the churn: the file is touched whenever any recovery-path behavior changes, by definition.

But three additional co-located concerns each iterate independently and produce edit collisions with the junction prose:

| Concern | Location in SKILL.md | Churn driver |
|---------|----------------------|--------------|
| Reviewer-activity detection | Step 3b: ~80-line jq detecting CR/Graphite/CodeAnt on a pushed SHA | Reviewer-set changes (new bot, new check name) require editing the skill |
| Wait-state predicate | Step 4d: same ~40-line jq appears twice (pre-check + loop body) | Predicate changes require two matching edits; duplication = drift risk |
| Classification contract | Step 5b: full prose re-statement of `pr-state.sh`'s `classify` rules | Rule changes require editing both `pr-state.sh` and `SKILL.md` in sync |

## Decision: extract, not split

**Splitting the skill is rejected.**

Every caller depends on fixpr's single Steps 0–7 contract and `=== fixpr complete ===` / `FIXPR_WRAP_STATUS:` / `FIXPR_WAIT_SUMMARY:` footer vocabulary. A physical split would require matching updates in `/wrap`, `/babysit-pr`, `phase-b-reviewer`, `phase-c-merger`, and the rule files that reference fixpr by step number. Extraction removes the per-PR edit surface while leaving the junction contract intact.

This follows the same remedy as:
- `hook-scripts.yml` hotspot (#681) — extracted deterministic script logic into `.claude/scripts/*.sh`
- `pm/SKILL.md` hotspot (#783) — extracted long prose into `.claude/skills/pm/references/*.md`

## Concrete remedy (Issue #788, implemented in PR that closes it)

Three targeted extractions, zero behavior change:

### 1. Classification contract → `pr-state.sh` is the single source of truth

The classification rules lived in `pr-state.sh`'s `classify` jq function (with an extensive block comment above it) AND were duplicated verbatim as prose in `fixpr/SKILL.md` Step 5b. `pr-state.sh` is now authoritative; Step 5b carries a pointer and a summary of the ordering invariants. Rule changes only require editing `pr-state.sh`.

### 2. Reviewer-activity detection → `.claude/scripts/reviewer-activity.sh`

The SHA-scoped reviewer-activity detection block was extracted from Step 3b into a standalone script. The script accepts `<PR_NUMBER> <PUSHED_SHA> <PUSHED_AT>` and emits the `{coderabbit, graphite, codeant}` boolean activity JSON on stdout. The trigger rate-cap / `@coderabbitai full review` decision logic stays in the skill — it involves judgment about the 2/hour cap and per-PR state and is deliberately in-turn.

### 3. Wait-state predicate → `pr-state.sh --wait-state-eval`

The ~40-line jq that computes `{head_moved, bots_pending, ci_pending, ci_failing, new_findings}` from a fetched bundle appeared twice identically in Step 4d (once in the DID_PUSH=0 pre-check, once in the wait loop body). Added as a new `--wait-state-eval <sha> <bundle_file>` mode in `pr-state.sh`. Both call sites in the skill replaced with a single-line script invocation.

## What was explicitly preserved

- Steps 0–7 sequential contract: unchanged
- `=== fixpr complete ===` footer: unchanged
- `FIXPR_WRAP_STATUS:` token: unchanged
- `FIXPR_WAIT_SUMMARY:` token: unchanged
- Step 3b rate-cap prose and `@cursor review` always-post rule: unchanged
- Step 4d loop control (sleep, cap, heartbeat, CR re-trigger): unchanged
- `dismiss-stale-bot-changes.sh` step sequence: unchanged
- `diff-survival-check.sh` Step 6a guard: unchanged

## Related

- Issue #681 — `hook-scripts.yml` hotspot, the structural precedent for extraction
- Issue #783 — `pm/SKILL.md` hotspot, the closest skill-file precedent
- `.claude/reference/script-extraction-audit.md` — registry of extracted scripts
- `.claude/scripts/reviewer-activity.sh` — new script from extraction 2
- `.claude/scripts/pr-state.sh` — `--wait-state-eval` mode from extraction 3
