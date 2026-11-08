# Recovery evidence after parser or execution failure

Issue #1974 extends the existing `/wrap` recovery audit and `/fixpr` wait snapshot. It changes evidence capture, never gate policy or authorization. `recovery-evidence.sh` resolves through the normal installed-worktree, home scripts, then repo fallback. Missing capture/storage stops recovery, never yields clean.

The actual capture blocks save stdout, stderr and exit status before parsing or routing. A valid gate object requires a boolean `met`, string-list `missing`, and nonempty HEAD. Exit0 must agree with met:true and no missing reasons; exit1 must agree with met:false. Empty, malformed, non-object, invalid-encoding, oversized or inconsistent results are unknown/errors. Exit2/4 remains a stop; exit3 keeps its existing not-open route. The complete valid object and hard-stop reasons remain in `last_gate`. A valid negative is distinct from failed execution.

A wait snapshot retains fetch and evaluator exits, their raw captures, HEAD/baseline, original bundle handle and a private byte-preserving copy of a readable bundle. Required predicate arrays, integer findings and boolean HEAD movement are checked. Missing/unreadable/oversized bundles are recorded as bundle-unavailable; invalid execution or shape cannot become clean. The pre-check and loop both call the same real capture function before reading predicates.

## Records and storage failures

- Wrap: `.prs["N"].wrap_sweep.recovery_audit` is latest; `.recovery_failures["capture-id"]` independently retains failures. Both are saved in one locked, explicit-repository session-state batch.
- Fixpr: `.fixpr_wait` is latest; `.fixpr_wait_failures["capture-id"]` independently retains failures. Unique-key locked literal assignments preserve sibling history. Archive is written first; if the later latest write fails, the previous latest remains and the failure is already indexed. Any failed write stops the caller. No jq program is passed to `--set`.
- Parsed pending CI/review alone is not failure history; failing CI, new findings, HEAD movement, execution/parse errors or unavailable evidence are. Clean snapshots never clear failure indexes.
- Mismatched inherited repository scope cannot redirect these writes: verified target scope is explicit. Capture metadata must match repo, PR and kind before any state index is issued.

Private raw captures live under `~/.claude/logs/recovery-evidence/OWNER/REPO/pr-N/{gate,wait}-ID/` (directories0700, files0600). Raw output is never put in routine model context or command arguments. Parsing/copying is bounded at8 MiB per capture/bundle; a larger stdout is still retained in its original raw file and classified as an error. Metadata and record JSON contain typed results and evidence handles, not raw stderr excerpts. Existing state helpers preserve their atomic-write behavior and unrelated fields.

## Lifecycle and targeted retrieval

Failure indexes have the lifetime of their containing session/handoff record; they are deliberately not truncated during an active recovery. Wrap may delete its merged handoff through the existing locked helper. Raw directories remain diagnostic logs until explicitly removed through normal log maintenance; no automatic deletion or invented expiry is introduced here. Completed-record deletion does not imply raw files were deleted. Each directory retains scoped meta/record JSON so it can still be found by repo/PR after an index is removed. Missing external/expired evidence remains unknown; refetch or rerun and save a new handle rather than claiming it is recoverable.

Use the saved capture directory for a small status projection, including after the original child shell has exited:

```bash
recovery-evidence.sh show --repo OWNER/REPO --pr N --kind wait --directory CAPTURE_DIR
```

An explicit detailed/verbose request can select raw stdout, stderr, fetch.stdout, fetch.stderr, audit or the retained bundle with `--raw NAME`. Default status prints classification, exits, HEAD, observation time and handles only. Preserve full logs; do not dump them merely to discover a verdict already in the record. The helper performs no GitHub writes and never turns a stored record into merge permission.
