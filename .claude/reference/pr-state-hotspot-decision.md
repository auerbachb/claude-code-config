# `pr-state.sh` hotspot decision: keep the CLI, extract pure jq programs

**Tracking:** Issue #980
**Decision:** KEEP the single `.claude/scripts/pr-state.sh` public CLI and extract two deterministic jq programs to `.claude/scripts/lib/`.

## Evidence

The churn report found nine merged PRs touching `pr-state.sh` between 2026-07-20 and 2026-08-03. The 732-line script mixes stable orchestration with two large, independently testable jq programs:

- the check-run projection used to build `check_runs.{total,passing,failing,in_progress,failing_runs,in_progress_runs,all}`;
- the bot-comment `classify`/`enrich` program used to build `new_since_baseline`.

Every consumer invokes `pr-state.sh` as a black-box subprocess. Skills and agents consume its printed tempfile path and JSON bundle; `merge-gate.sh`, `escalate-review.sh`, and `poll-watermarks.sh` do the same directly or transitively. No consumer sources the script. The two focused tests were the coupling smell: they used `sed` to extract jq source from shell quoting, so harmless shell edits could break test discovery and single quotes inside the jq program required escaping.

## Ownership after extraction

| Owner | Responsibility |
|---|---|
| `pr-state.sh` | CLI parsing; repo/PR scoping; current HEAD; GraphQL threads; paginated checks, statuses, and comments; special modes; final schema assembly; documented exit behavior |
| `lib/pr-state-cr-split.jq` | Pure check-run projection after deduplication |
| `lib/pr-state-classify.jq` | Pure timestamp-filtered bot-comment classification and count rollup |

The split is internal only. Callers still resolve and invoke `pr-state.sh`; they do not call either jq file.

## Preserved contract

- All existing flags and stdout forms remain unchanged.
- The full-snapshot JSON key set and values remain unchanged, including GitHub App identity on projected check runs.
- Repo scoping, reviewer/current-HEAD/check/thread aggregation, pagination, and `gh` error mapping remain in the CLI.
- Existing exit-code meanings remain `0/2/3/4/5`. An incomplete installation is a runtime failure and uses the existing code `5`.
- `--help`, `--infer-candidates`, and `--wait-state-eval` exit before the full-snapshot filter guard and remain usable without the extracted files.

## Deployment

Production resolvers select `pr-state.sh` from `~/.claude/skills-worktree/.claude/scripts/`, `~/.claude/scripts/`, or the current repository's `.claude/scripts/`. The canonical installation is a complete repository checkout, so `.claude/scripts/lib/` is already co-located with the selected script; there is no enumerated copy manifest to extend. A partial manual copy now fails early with the exact missing sibling path instead of reaching GitHub and failing later. Tests that replace `pr-state.sh` with a stub remain unaffected because they never execute the production script.

## Deliberate non-extractions

`--infer-candidates`, `--wait-state-eval`, PR discovery, sections 1–2 and 4–5, and final assembly in section 7 stay in `pr-state.sh`. They share the CLI's state, error mapping, or sequencing and do not have the fragile dual-definition pattern that justified the jq extraction. Splitting the public CLI would multiply path resolution and make schema evolution harder without reducing the observed churn source.
