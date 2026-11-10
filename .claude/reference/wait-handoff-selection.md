# Wait evidence and selected handoffs

The actual `/fixpr` loader sources `scripts/lib/fixpr-wait-evidence.sh` beside
the explicitly resolved recovery helper, or from the standard skills-worktree,
user-script, then repository-script locations. Copy the whole loader into an
isolated wait child and pass its existing helper/scope/HEAD/baseline inputs.
The child keeps its task checkout as cwd; functions and variables from a parent
shell are not inherited. Missing code or storage stops without a clean verdict.

## Scoped and legacy records

The first persistence call pins one lane for this wait and its repo/PR/HEAD.
An existing canonical scoped file keeps the established explicit scoped setter
behavior. If absent, `polling-state-gate.sh N --resolve-handoff --repo owner/repo
--root-repo CHECKOUT` reuses the gate's candidate selection and offline state,
HEAD and repository checks. It returns `selected-handoff/v1` JSON containing
path, lane, owner, PR and HEAD, and performs no GitHub call or creation.

The returned target must be the helper's canonical path for that exact lane.
A legacy record additionally needs its embedded numeric PR, owner/repo and HEAD
to agree with the verified task. An unattributed same-number flat file is never
assigned to whichever repo happens to be active. Malformed/missing/foreign
state stops; inherited unrelated repository state cannot redirect the target.

Legacy writes stay in place. `handoff-state.sh --legacy-flat --require-existing
--expect-pr N --expect-owner owner/repo --expect-head SHA --set N 'FIELD=VALUE'`
checks identity under the same per-record advisory lock as the read/modify/write.
The expectation flags are opt-in, required together and only supported for an
existing set/append target. They cannot create a partial shadow. A scoped
counterpart appearing before the guarded update refuses the legacy write.
Deleted, migrated or differently attributed/reheaded records stop the waiter;
it does not silently switch targets between failure-history and latest writes.

Full existing fields survive literal field updates, including unknown fields,
recovery notes and previous history. Failure captures are archived before the
latest status, as in `recovery-evidence.md`. A failed selection or write retains
private raw capture and prints its evidence path. Stored evidence is diagnostic;
it does not grant ownership, certify a merge or supersede a live source check.

## Repair and limits

When a legacy record lacks attribution, independently verify its complete PR
and repository context before an explicit repair. For a verified record only,
`handoff-state.sh --legacy-flat --set N '.owner_repo="owner/repo"'` adds the
known owner without replacing the other fields. Never infer it from the PR
number or cwd. Verify HEAD against the task's real sources too. Malformed or
missing records require recovery from complete canonical task evidence through
the established handoff helper, not a partial wait-only record.

Restart enrollment/selection after an explicit migration or repair. This path
does not run the bulk migration tool, copy records between repositories, or
invent missing identity. Locks serialize cooperating writers of one record;
this is not a distributed ownership reservation or a cross-file filesystem
transaction. External writers must follow the existing helper contract.
