<!-- churn-hotspot: .claude/scripts/handoff-state.sh -->
# `handoff-state.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #1461 (`.claude/scripts/handoff-state.sh` churn hotspot). Not auto-loaded.

| Field | Value |
|-------|-------|
| **Verdict** | KEEP — no extraction, no split; two header-contract drifts fixed |
| **Decided** | 2026-08-29 |
| **Issue** | #1461 |
| **Reporter** | `/wrap` churn detection after PR #1454 merged |
| **Snapshot at filing** | `score 3`, `conflict_rounds 0`, `pr_count 3` (PRs #1337, #1378, #1423) |
| **Snapshot at adjudication** | `score 5`, `conflict_rounds 0`, `pr_count 5` (+ PRs #1458, #1487) |

## The problem being read

`.claude/scripts/handoff-state.sh` is the **single write path** for every per-PR
handoff file (issue #682). Phase A/B/C agents, `polling-state-gate.sh`,
`dismiss-stale-bot-changes.sh`, `/wrap`'s delete sweep and `handoff-migrate.sh`
all route through it, because a lock only some writers respect is not a lock
(#639). `handoff-files.md` names `handoff-state.sh --help` as its canonical
contract.

Being the single write path is what put it in the report. Unlike most files this
detector surfaces, though, its churn *is* corrective: three of the five PRs close
filed defect reports. That deserved a real look rather than a reflexive KEEP.

## Churn attribution — per-PR evidence

Every row below comes from `git show --numstat` on the merge commit; the PR set
comes from `churn-hotspots.sh --json`. The window opens 2026-08-15.

| PR | Issue | Δ in this file | Files in commit | Nature |
|----|-------|----------------|-----------------|--------|
| #1337 | #1302 | +50 / −1 | 13 | **Bug fix, round 1** — "Phase B writes handoffs to the flat path; Phase C reads the scoped one". Made omission *warn*. |
| #1378 | #1357 | +94 / −1 | 3 | **Bug fix, independent** — `--set` stored a raw jq program as a string and exited 0, clobbering the previous value. |
| #1423 | #1366 | +284 / −78 | 21 | **Bug fix, round 2 of the same defect** — warning left the wrong path reachable by default; derive-or-refuse. **Created `lib/pr-scope-resolver.sh`.** |
| #1458 | #1406 | **+1 / −1** | 72 | **Mechanical sweep** — `script-usage.log` stderr-guard ordering, applied identically across 72 files in one commit. |
| #1487 | #1438 | +16 / −5 | 2 | **Documentation correction** — the header PR #1423 wrote claimed both flat-path escapes were silent; one emits a diagnostic. |

`conflict_rounds` is **0**: no PR in the window collided with another on this
file, and none of the five was a revert or a re-fix of a sibling PR's regression.

## Churn classification

**Two defect threads plus two passengers — and the thread that produced most of
the volume closed by extracting, inside this very window.**

- **Thread 1 (scope resolution): PRs #1337 → #1423, 334 of the 445 added lines.**
  One defect, fixed twice, because the first fix was a warning rather than a
  behavior change. The second fix is the interesting one: it did not add more
  policy to this file — it **created `lib/pr-scope-resolver.sh`** and pointed both
  `handoff-state.sh` and `polling-state-gate.sh` at the shared resolver, so one
  checkout can no longer resolve to two different repo keys depending on which
  helper is asked. (`handoff-migrate.sh` moved onto the same scoping contract in
  that PR but consumes `lib/repo-normalizer.sh`, not the resolver — it is handed
  the owner/repo rather than deriving it.) The extraction this churn was calling
  for has already happened.
- **Thread 2 (`--set` value classification): PR #1378, one round, closed.**
  Unrelated to thread 1; no follow-up issue is open against it.
- **PR #1458** changed one line as part of a 72-file sweep. The file was a
  passenger and the change carries no signal about its design.
- **PR #1487** corrected prose in the header, not behavior.

So the corrective churn is **one policy defect (two rounds) and one input-validation
defect (one round)**, not accumulation of independently-owned concerns.

## Options considered

### Option A — KEEP as-is (chosen)

No structural change. Record the reasoning; fix the two header drifts found while
auditing (below).

**Rationale.** Every concern in this file that has, or could plausibly gain, a
second caller is *already* extracted:

| Concern | Owner today | Other callers |
|---------|-------------|---------------|
| Lock lifecycle | `state-lock.sh` (#639) | `session-state.sh`, `polling-state-gate.sh` |
| owner/repo case key | `lib/repo-normalizer.sh` (#704) | 5 scripts |
| cwd → owner/repo | `lib/pr-scope-resolver.sh` (#1366) | `polling-state-gate.sh`, this script |
| Flat-escape policy, derived-scope diagnostics | this script | none — it *is* this script's contract |
| `--set` value classification + jq-program refusal | this script | none |
| `--append` dedup contract (#682) | this script | none |

The `merge-gate.sh` extract-not-split precedent (`merge-gate-hotspot-decision.md`)
applies when **duplication** exists across independently-evolving paths — 104
duplicated lines there. No duplication exists here, in this file or across the
tree (see Option B).

### Option B — Extract the `--set` value classifier into a shared lib

Not chosen. This was the strongest candidate, because `session-state.sh` faces
the *same* corruption class (issue #625's origin was "an unevaluated jq filter
expression passed as a value"), and PR #855 already had to hand-align the two
scripts' `--argjson` probes once.

Measured against the tree, it does not hold up: the two scripts solve that class
with **different mechanisms**, not duplicated code.

- `session-state.sh` catches it with the schema-driven **field-type contract**
  (#625/#640): the write is rejected when a known array/object field would end up
  the wrong type in the final document.
- `handoff-state.sh` has no schema to check against, so PR #1378 added a
  **three-signal jq-program refusal** (starts like a path expression, contains a
  jq operator, compiles as a jq program) with `#` and `;` bail-outs that exist
  specifically because a probe that evaluates can hang *while holding the state
  lock*.

The only genuinely shared thing is the 3-line `--argjson`-as-probe idiom, whose
subtlety lives in the comments, not the code. Extracting three lines to keep two
different guards "consistent" would couple two contracts that are deliberately
different, and would put a hang-sensitive probe behind an extra indirection.

### Option C — Extract the scope-resolution policy block

Not chosen — **it is already extracted, correctly.** The *derivation*
(cwd → `owner/repo`, identity validation) is `lib/pr-scope-resolver.sh`. What
remains inline is **policy**: which of `--owner-repo` / `--legacy-flat` /
`CLAUDE_HANDOFF_FLAT_OK` / `$CLAUDE_SESSION_REPO` / cwd wins, which combinations
are usage errors, when a derived scope warns, and when an un-migrated flat record
must refuse a write outright. That policy is this script's contract; moving it
would relocate the contract without giving it a second owner.

### Option D — Split into sibling scripts per mode

Rejected. `--path`/`--get`/`--create`/`--init`/`--set`/`--append`/`--delete` share
one lock discipline, one path resolver and one dedup contract; splitting them
recreates the multi-writer, multi-lock-path failure that #682 and #639 exist to
prevent. Same conclusion as `session-state-script-hotspot-decision.md` Option D.

## Divergences from the CodeRabbit plan

The plan reached the same verdict (documentation-only KEEP) and its document
shape is followed. Four of its factual claims were checked and not carried over.

1. **"By-design evolution along two independent hardening threads."** Not what the
   record says. Issues #1302 (*"Phase B writes handoffs to the flat path; Phase C
   reads the scoped one"*), #1357 (*"…silently stores a raw jq expression as a
   string and exits 0"*) and #1366 (*"…still reaches the dead flat path by
   omission"*) are defect reports, and #1438 reports drift the #1423 header
   introduced. Calling that "by-design hardening" would launder the evidence. The
   KEEP verdict stands on different grounds — see Option A.
2. **`pr_count 3` / `score 3`.** Stale by the time of adjudication; the live
   detector reads 5/5. Recording 3 would arm the 2× re-surfacing gate at 6 instead
   of 10, re-opening this file on noise.
3. **"Scope resolution … serve[s] the single `handoff-state.sh` caller."**
   `lib/pr-scope-resolver.sh` already has two production consumers plus its own
   test. The plan appears to describe the pre-#1423 tree.
4. **Documentation-only, no code change.** Two real header drifts exist (below).
   `usage()` prints the header verbatim and `handoff-files.md` points callers at
   `--help`, so header drift is contract drift.

## Defects found and fixed

Both are `--help`-versus-behavior drift in the leading comment block. Neither
changes runtime behavior.

1. **`DEPENDENCIES` under-reported the hard requirements.** It named
   `jq, mktemp, mv` and `state-lock.sh` alone, but `lib/repo-normalizer.sh`
   (#704) and `lib/pr-scope-resolver.sh` (#1366) are also sourced at startup and
   each exits 5 when missing. Reproduced before the fix: a directory holding
   exactly the documented dependencies exits 5 on the first invocation. The list
   now names all three, with the issue that introduced each.
2. **The exit-5 row under-reported its own causes.** It read "Write failure
   (mktemp / mv)"; exit 5 is also returned by three missing-library sites and by
   `rm` failure under `--delete`. The row now covers all three causes and states
   the common invariant — the handoff file is left exactly as it was.

**Guards added** (`handoff-state.test.sh`, 166 → 175 assertions, no existing test
modified), all fail-closed — each asserts it discovered something before asserting
the discovered set is documented, so a grep that stops matching fails the suite
instead of passing vacuously:

- every `*_LIB="${SCRIPT_DIR}/…"` requirement read out of the script body must be
  named in the `--help` `DEPENDENCIES` block;
- every file that block names must exist on disk (no phantom dependency);
- a stub built from **only** the files that block names must run — the list has to
  be sufficient, not merely present;
- a missing sibling library must exit 5, pinning the widened row's claim;
- every literal `exit N` in the script (comment lines stripped, so the header
  describing a code cannot be what makes it look documented) must have an
  `EXIT CODES` row.

Negative control: the new assertions were added before the header fix and three of
them observed to fail against the unmodified script (`172 passed, 3 failed`), then
pass after it (`175 passed, 0 failed`).

## Preserved invariants

Nothing below changed, and no future cleanup of this file may change them silently:

- **CLI surface** — `--path`, `--get`, `--create`, `--init`, `--set`, `--append`,
  `--delete`; scope flags `--owner-repo`, `--legacy-flat`, `--require-existing`,
  all of which must precede the mode flag (trailing ones are a usage error, #1366).
- **Exit codes** — 0 success, 2 usage/unresolvable scope, 3 not found, 4 jq
  parse/eval failure and the #1357 refusal, 5 on-disk failure, 6 lock timeout.
- **Scope resolution order** — `--owner-repo`, then `$CLAUDE_SESSION_REPO`, then
  the cwd's `origin`; unresolvable exits 2 having written nothing. Omission is
  never a request for the flat path (#1366).
- **Flat escapes** — `--legacy-flat` is silent; `CLAUDE_HANDOFF_FLAT_OK=1` notes
  the scope it bypassed when the context resolves one (#1438). An explicit
  `--owner-repo` beats the variable and says so.
- **Lock discipline** — writes acquire `state_lock_acquire` before reading and
  re-assert the lock immediately before the commit; a stolen lock re-execs
  (bounded) rather than overwriting. Reads are lock-free because `mv` is atomic.
- **Dedup contract (#682)** — string arrays dedup by value, `findings_dismissed`
  by `.id`; unknown fields are always preserved.
- **`--require-existing`** — checked *inside* the lock, so it is race-free where a
  caller's own `-e` test is not (#1423).

Concurrency and scoping behavior is pinned by `handoff-scoping.test.sh`
(153 assertions, unchanged by this decision).

## Reconsideration criteria

Re-open the extraction question when any of these is observed — not on PR count:

- `conflict_rounds > 0` appears for this file (two writers colliding is the signal
  PR frequency is a poor proxy for).
- A **third** consumer needs the `--set` jq-program refusal, or `session-state.sh`
  abandons the field-type contract for this file's three-signal guard — at that
  point the two mechanisms have converged and Option B becomes real.
- A defect thread opens that is *not* about scope resolution or value
  classification, i.e. a genuinely new concern accumulating in this file.
- Detector score reaches **10** (2× the recorded baseline of 5), per
  `churn-hotspot-baselines.json`.

## Related

- `session-state-script-hotspot-decision.md` (#952) — the sibling state-writer's
  KEEP; closest structural precedent, same already-extracted-concerns argument
- `state-file-contracts-hotspot-decision.md` (#1012) — KEEP for the mechanism doc
- `merge-gate-hotspot-decision.md` (#936) — the extract-not-split precedent, which
  requires duplication that does not exist here
- `chip-offer-registry-hotspot-decision.md` (#1464) — same adjudication shape,
  KEEP plus a header-drift fix pinned by a fail-closed guard
- `handoff-missing-owner-repo-decision.md` — why omission stopped being a fallback
  (#1366) and how the two flat escapes differ (#1438)
- `.claude/rules/handoff-files.md` — names `handoff-state.sh --help` as canonical
- `.claude/scripts/tests/handoff-state.test.sh`, `handoff-scoping.test.sh` — the
  two suites that pin this file
- `.claude/reference/churn-hotspot-baselines.json` — the snapshot feeding the
  re-surfacing gate
