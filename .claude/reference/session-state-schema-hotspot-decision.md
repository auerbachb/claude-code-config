# Session-State Schema Hotspot Decision

Reference for Issue #964 (`.claude/reference/session-state-schema.json` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the combined contract and representative document; **deduplicate toward it**

Keep `.claude/reference/session-state-schema.json` intact as the canonical source for both the
machine-readable `_field_types` maps and the representative session-state document. Remove the
stale typed-field enumeration from the `session-state.sh` header, correct the ownership statement
in `state-file-contracts.md`, and document how future fields should update the contract.

The file's churn is contract churn: its recent edits added or corrected state that the workflow
actually persists. Moving the representative document would transfer those edits to another file,
create another ownership boundary, and require migrating current tests and named references.

## 1. Trigger and current evidence

Issue #964 recorded 10 merged PRs touching the schema after 2026-07-19. Current `main` adds
PR #982, producing 11 touches: PRs #654, #659, #690, #728, #747, #765, #820, #825, #828,
#867, and #982.

Those changes fall into related session-state contract work:

| Churn class | PRs | Contract change |
|-------------|-----|-----------------|
| Type and scope contract | PRs #654, #659, #728 | Nested type guards, per-repo state, and lowercase scope identity |
| PR lifecycle state | PRs #690, #747, #765 | Conflict streaks, poll watermarks, and overlap-aware merge holds |
| Orchestration posture | PR #828 | Persisted refill pause/scope state |
| Scheduling lifecycle | PRs #820, #825, #867, #982 | Backoff fields, corrected scheduler durability, reconciliation, and Monitor identity |

The file has two deliberate consumers:

- `session-state.sh` and `session-state-audit.sh` load
  `._field_types.top_level` and `._field_types.pr_nested` at runtime.
- `scheduling-primitive-alignment.test.sh` checks representative scheduling values and Monitor
  identity fields in the example. The example is therefore tested contract documentation, not
  unused prose. `handoff-files.md` also points agents to `_token_exhaustion_example` by name.

## 2. Decision: keep one canonical artifact

**Splitting is rejected.** A separate example fixture would still change whenever persisted state
changes, while type-guarded additions would continue to change `_field_types`. It would not reduce
the underlying churn and would add a second file that callers must discover and keep aligned.

**Extracting the prose is rejected for now.** The `_`-prefixed descriptions sit beside the exact
shapes they qualify. Moving them would make the representative document less self-explanatory
without changing the edit frequency caused by new state fields.

**KEEP + targeted deduplication is chosen.** The schema remains byte-for-byte unchanged in the
Issue #964 remediation. Downstream documentation names it as authoritative instead of mirroring
its field list.

This differs from CodeRabbit's initial extract-not-split proposal because that plan predates
PR #982 and did not account for the alignment test's direct consumption of example values. It
retains the useful parts of that proposal: an explicit adjudication record, removal of the stale
header mirror, and a contributor checklist.

## 3. Canonical ownership

| Content | Canonical owner | Consumer behavior |
|---------|-----------------|-------------------|
| Type-guarded top-level and per-PR fields | `session-state-schema.json` `_field_types` | Scripts load the maps; comments and docs point here rather than listing fields |
| Representative session-state shapes | `session-state-schema.json` example document | Contract tests assert behaviorally important shapes and lifecycle vocabulary |
| Scoping, locking, migration, and type rationale | `state-file-contracts.md` | Explain why the contract works without duplicating its full field inventory |
| Runtime parsing and graceful degradation | `session-state.sh` and `session-state-audit.sh` | Preserve behavior when the schema is missing or cannot be parsed |

## 4. What is preserved

- `schema_version` remains `2`.
- `._field_types.top_level` and `._field_types.pr_nested` remain the runtime jq paths.
- Repo-scoped state remains under `.repos["<owner>/<name>"].prs["<N>"]`.
- Unknown fields remain forward-compatible and unvalidated unless explicitly type-guarded.
- A missing or invalid schema still warns and disables type checks for that invocation instead of
  blocking all state reads and writes.
- The representative example, including `_token_exhaustion_example` and Monitor identity fields,
  remains in place.

## 5. Targeted remediation

1. Replace the `session-state.sh` header's hand-maintained field enumeration with a direct pointer
   to the schema's `_field_types` maps. The runtime loader already follows that source.
2. Update `state-file-contracts.md` so it no longer claims the script header owns the typed-field
   list. Document the representative example and the field-change checklist there.
3. Register this decision in the reference catalog.

No runtime code, state migration, schema edit, or compatibility shim is required.

## 6. Future edits and reconsideration

For a new field:

- add it to `_field_types` only when `session-state.sh` must enforce its JSON type;
- update the representative object when the shape is part of the documented cross-agent contract;
- update a focused alignment test when lifecycle vocabulary or a coupled field set matters;
- leave untyped forward-compatible fields out of `_field_types`; and
- put rationale in `state-file-contracts.md`, not in a second field inventory.

Reconsider this KEEP verdict only if independent consumers need incompatible representative
documents, the file becomes difficult to validate as one JSON object, or unrelated concerns begin
changing on separate cadences. Raw touch count alone is not a reason to split a canonical schema.

The traceability marker on Issue #964 is:
`<!-- churn-hotspot: .claude/reference/session-state-schema.json -->`.

## Related precedent

- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP + targeted deduplication
  when churn follows one cohesive contract;
- `.claude/reference/fixpr-hotspot-decision.md` — extract only independently changing machinery;
- `.claude/reference/churn-hotspots.md` — observational detector semantics and adjudication goal.
