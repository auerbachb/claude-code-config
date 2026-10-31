---
name: issue-maker
description: Capture and manage GitHub issues incrementally. Dispatches create, batch, update, retract, or portable-export work to one on-demand module for the current phase; does not read the module catalog wholesale.
triggers:
  - open an issue
  - new issue
  - make an issue
  - file an issue
  - track this
  - log this
  - capture this
  - issue-maker
argument-hint: "<issue description | 'batch: ...' | '/update #N: ...' | 'close #N' | rapid-fire | --export-prompt>"
---

# /issue-maker — incremental issue capture

This entry point is deliberately small. It routes the current operation and phase to one module, then loads additional material only when that phase calls for it. **Never read every module or reference to discover what might be relevant.** The installed skill harness loads this entry point; verify behavior through explicit reads rather than assuming imports are lazy. There are no `@` imports here.

## Always-on contract

- This skill captures, edits, and retracts issues. It does not implement code, create branches or worktrees, or start `/start-issue` unless the user accepted the inline execution offer recorded in session state.
- Preserve the repository's safety, authority, issue ownership, and required workflow gates. A selected module cannot waive them.
- Do not write issue bodies from the user's sentence without the reflection, dedup, validation, and reporting steps required by the selected operation.
- Preserve the seven-section body and captured footer on creates, the confirmed-edit gate on updates, chain-aware handling on retract, and the single post-batch handoff offer.
- Recovery state must identify operation, module/phase, issue/repository, current evidence, and next step. On compaction/restart, reload this entry and the session-state module, revalidate pending gates, then load only the active phase module. Do not replay completed phases.

## Chip invocation contract

When `spawn_task` emits an on-request chip (or a fallback block is printed), the `prompt` MUST open with the `**Model:**` line from model selection, then `**Effort:**`, then the model-guard preamble from [chip-launching.md](../../reference/chip-launching.md), with no blank line between them. The short summary must repeat both lines. If the parent thread is on Fable, show the pre-click model-guard warning. Read chip-launching only when constructing a chip prompt.

## Dispatch

1. Classify the request before reading a procedure:
   - New issue description → `create:reflect`; explicit multi-issue input (`batch:` or list of distinct requests) → `create:reflect` plus `batch:chain`.
   - `/update #N`, `edit #N`, or equivalent → `update:edit`.
   - `close #N`, `retract #N`, or equivalent → `retract:close`.
   - Explicit chip/handoff request or handoff replay → `offer:handoff`; tally, full issue-body reprint, inline-offer acceptance/decline/refresh → `report:status`. These operations file nothing.
   - `--export-prompt` → `export:prompt` only; it files nothing.
2. For every capture-session operation except portable export, initialize or recover the session by reading `session:state` once per context. For portable export, do not enter capture mode.
3. Resolve a module with the helper and read **only the emitted path**:
   ```bash
   # Set OPERATION and PHASE from the classification above (or recovered checkpoint).
   # Require both; never silently default an update/retract/resume to create.
   : "${OPERATION:?classify the requested operation first}"
   : "${PHASE:?select the current phase first}"
DISPATCHER=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/skills/issue-maker/scripts/dispatch-module.sh" \
  "$HOME/.claude/skills/issue-maker/scripts/dispatch-module.sh" \
  ".claude/skills/issue-maker/scripts/dispatch-module.sh"; do
  [ -x "$candidate" ] && { DISPATCHER="$candidate"; break; }
done
[ -n "$DISPATCHER" ] || { echo "FATAL: issue-maker dispatcher not found" >&2; exit 1; }
MODULE=$(bash "$DISPATCHER" "$OPERATION" "$PHASE") || exit $?
   printf '%s\n' "$MODULE"
   ```
   Use the resulting absolute path with the file-read tool. The helper checks the requested path and never opens it or scans sibling files. Invalid operation/phase is an error; a missing selected module is a blocker with its path in the recovery note.
4. Before any remote write, resolve (without reading) the remaining required module paths for the chosen workflow; a missing path blocks the write. For a create this includes `create:file` and `create:postfile`, plus `batch:chain`, `create:increment-draft`, and `create:crossrefs` when a chain was selected. Do not preflight unrelated branches. Follow that module's phase triggers. For create, load `create:dedup` only after a title and problem statement exist and duplicate screening is next; load `create:file` only after the draft is ready and dedup gates clear; load `create:increment-draft` only after sizing selects an increment chain; `create:crossrefs` only when issue references or chain links exist; load `create:postfile` only after the issue is filed and the final report/handoff is due. For every batch or increment chain, load `batch:chain`; a chain also loads `create:increment-draft` and `create:crossrefs` only after sizing selects it. Load a referenced document only at the explicit point named by the module; nested references are not preloaded.
5. After `session:state` has loaded and defined `set_log`, persist a checkpoint before each operation-phase read and after each phase completes: operation, phase/module, issue (or null), repository, current evidence, and next step. The initial `session:state` read cannot be checkpointed before its helper exists; `export:prompt` is outside capture state and never checkpoints. Reuse a module already read in the current valid context. Re-read only when the context was compacted/restarted, the module changed, or the active phase was not previously loaded. The operation log is the recovery source; do not use memory to claim a phase completed when no evidence was persisted.

## Module index (discovery only; do not read the entries as a group)

| Operation / phase | Module | Trigger |
|---|---|---|
| session / state | `modules/session-state.md` | Start or recover a capture session |
| create / reflect | `modules/create/reflect-and-draft.md` | One new issue, before duplicate check |
| create / increment-draft | `modules/create/increment-draft.md` | A sizing result requires an increment chain |
| create / dedup | `modules/create/dedup.md` | Draft exists and duplicate screening is next |
| create / file | `modules/create/file.md` | Draft and dedup gates are clear |
| create / crossrefs | `modules/create/crossrefs.md` | Related issue references or chain links are needed |
| create / postfile | `modules/create/postfile.md` | An issue is filed; report/handoff is due after the final issue |
| batch / chain | `modules/batch.md` | Multi-issue batch or increment chain |
| update / edit | `modules/update.md` | Existing issue edit request |
| retract / close | `modules/retract.md` | Existing issue close request |
| offer / handoff | `modules/handoff.md` | Explicit chip/block or replay request |
| report / status | `modules/create/postfile.md` | Tally, body reprint, offer response/refresh |
| export / prompt | `modules/portable-prompt.md` | Explicit portable prompt export |

For the shared contract, evidence boundaries, measurement recipe, and ordered migration roadmap for `/pm`, `/subagent`, `/wrap`, and `/pr-monitor-and-manage`, see [incremental-skill-loading.md](../../reference/incremental-skill-loading.md). Read it only for implementation, audit, or migration work—not during ordinary issue capture.
