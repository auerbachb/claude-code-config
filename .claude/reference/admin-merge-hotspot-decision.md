# `admin-merge.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #994 (`.claude/scripts/admin-merge.sh` churn hotspot). Not auto-loaded.

## The problem being read

`.claude/scripts/admin-merge.sh` was touched by 7 distinct merged PRs since
2026-07-21: #616, #658, #726, #739, #761, #878, and #968.

The script is the single entry point for the branch-protection bypass workflow:
it verifies merge-readiness, confirms solo ownership, diagnoses the bypass shape
(toggle vs plain), and either prints or executes the appropriate merge command.
Every new bypass capability in the 2026-07 window required a corresponding change
here because the script owns the boundary between "Claude may act" and "human must
act." The churn signal reflects a series of feature and correctness additions to
that boundary, not maintainability problems.

## Functional sections

The 877-line script divides into seven functional sections:

| Section | Lines (approx) | Purpose |
|---------|----------------|---------|
| A — Header / docs | 1–101 | Modes, options, exit codes |
| B — Bootstrap / arg parsing | 102–230 | `set_mode`, arg parsing, PR state check |
| C — Authorship guard | 231–256 | `pr-authorship.sh` delegation (issue #733) |
| D — Merge-gate pre-flight | 290–420 | `merge-gate.sh` check, clean-BEHIND allowance, hard-blocker filter |
| E — Solo-owner heuristic | 420–480 | CODEOWNERS parsing, admin count check |
| F — Shape detection | 480–570 | `enforce_admins`, `STRICT`, `BYPASS_MODE`, bypass command builder |
| G — Mode implementations | 563–877 | `print`, `launch-terminal`, `auto-plain`, `execute` |

## Churn attribution — per-section evidence

### PR #616 — Sections B, G

Removed the `.merged` field from `gh pr view` JSON and replaced `'.merged //
false'` with `'(.state == "MERGED")'` throughout. Added a 3-attempt
read-after-write retry loop in the `--execute` mode's post-verify block, with a
2-second sleep between attempts and an explicit exit 7 when all attempts exhaust.

**Driver:** API reliability. The `.merged` boolean was less reliable than
inferring state from `.state`; the read-after-write retry handles eventual
consistency on repos with queued/deferred merges — `gh pr merge --admin` can
return before GitHub's state API reflects the merge. This was a correctness fix
independent of any other change.

### PR #658 — Sections D, G

Added `CLEAN_BEHIND_OK`, `BEHIND_PRESENT`, `CBC` (clean-behind-check.sh path
discovery), and `CBC_ARGS` variables. Updated the hard-blocker filter to allow a
clean `BEHIND` past the guard. Added `clean-behind-check.sh` invocation (exit 0
= safe). Added re-validation of the clean-BEHIND state in `--execute` mode before
touching branch protection. Updated the bypass-mode detection to set
`BYPASS_MODE=plain` when `enforce_admins==false && strict==true &&
CLEAN_BEHIND_OK==true`.

**Driver:** Issue #631 — the "clean BEHIND, safe to bypass" allowance. A PR
BEHIND base with no file overlap between main's new commits and the PR's changed
files does not need a rebase; an admin merge is safe. This required programmatic
detection of the "safe" subset of BEHIND states so the guard could distinguish
mechanical staleness from content conflict.

### PR #726 — Sections A, F, G

Added `BYPASS_MODE` variable (toggle vs plain), `STRICT` reading from the
branch-protection API, conditional bypass-command builder (plain omits protection
toggle calls), conditional `print_warning_block()` output (plain vs toggle), and
a new execute-mode branch for the plain shape that runs `gh pr merge --squash
--admin` without touching protection settings. Updated exit code 6 documentation
to name the new condition (`enforce_admins==false` and the strict+clean-BEHIND
plain bypass does not apply).

**Driver:** Issue #720 — when `enforce_admins` is already off but
`required_status_checks.strict` blocks a clean-BEHIND branch, a bare `--admin`
merge bypasses the staleness constraint without modifying any protection
setting. The distinction between "toggle shape" and "plain shape" was needed to
give Claude a structurally safe auto-execute path (plain) while keeping the
protection-modifying toggle print-only.

### PR #739 — Sections A, B, C

Added `--allow-nonauthor` flag and `ALLOW_NONAUTHOR=false` variable to arg
parsing. Added the authorship guard block (Section C): discovers `pr-authorship.sh`
from three candidate paths, runs it, and refuses exit 1 on any non-zero result
(fail-closed). Updated the header docs for `--allow-nonauthor` and updated exit
codes 0/1 in the header to include the authorship guard refusal.

**Driver:** Issue #733 — authorship guard. A bypass merge is the most
consequential PR write; restricting it to the authenticated user's own PRs
prevents accidental writes to collaborators' PRs. `pr-authorship.sh` is the
single source of truth; `admin-merge.sh` delegates to it rather than duplicating
the detection logic.

### PR #761 — Sections A, B, G

Added `--auto-plain` mode and `--ac-verified` option to arg parsing and to the
header. Added `AC_VERIFIED=false` variable. Added the full `--auto-plain`
implementation in Section G: hard shape gate (exit 8 on non-plain `BYPASS_MODE`),
AC gate (exit 8 without `--ac-verified`), repeat guard (read/write marker in
`~/.claude/admin-merge-auto/`), mandatory TOCTOU re-validation of
`clean-behind-check.sh`, `gh pr merge --squash --admin` execution, 3-attempt
read-after-write retry, and an evidence report on stdout. Updated exit code
documentation (added exit 8).

**Driver:** Issue #754 — the plain shape is structurally safe for Claude to
auto-execute: it contains no protection-modifying call, and a non-plain
`BYPASS_MODE` refuses before any write. `--execute` was originally the only
entry point for execution, but it is user-only *because* it can also run the
toggle dance. A separate `--auto-plain` mode that is structurally incapable of
the toggle dance was required so the boundary is enforced by structure, not
prose.

### PR #878 — Section G

Added `release_issue_claim()` helper function (best-effort, never changes exit
status). Called it in three places: after the `FINAL_MERGED == true` check in
`--auto-plain`, after the same check in `--execute`'s plain-shape branch, and
after the same check in `--execute`'s toggle-shape branch.

**Driver:** Issue #873 — issue claim release on merge. When a PR merges, the
issue it closes should become startable again immediately. The function looks up
the linked issue via `pr-issue-ref.sh` and calls `issue-claim.sh --release`;
failures are warnings only, since the merge has already completed.

### PR #968 — Sections D, G

Added `REVIEW_DECISION_BLOCKER_RE` regex constant (the full branch-protection
`reviewDecision` failure message pattern). Added `clean_behind_evidence_allows_admin()`
function that accepts the helper's JSON and exit code, allowing exit 0 directly
and additionally accepting exit 1 when JSON evidence shows the only residual
blockers are reviewDecision notes `admin-merge.sh` is independently allowed to
bypass. Added `CBC_JSON` and `CBC_RC` state variables to capture the helper's
output for re-use. Added `NON_BEHIND_HARD_BLOCKERS` filter. Updated the
`HARD_BLOCKERS` jq filter to use the regex rather than a substring match.
Improved error messaging to distinguish "BEHIND but unsafe" from "other
blockers."

**Driver:** Issue #947 — gate-filter asymmetry. `clean-behind-check.sh` runs
its own internal `merge-gate.sh` call, which can exit 1 solely because the
branch-protection `reviewDecision` note is present — the same note
`admin-merge.sh` is already allowed to step over. Before this PR, exit 1 from
the helper was treated uniformly as "unsafe," making `--auto-plain` unreachable
on exactly the PRs where it was most needed. The structured JSON evidence path
lets `admin-merge.sh` distinguish the known asymmetry (safe to proceed) from
genuine mechanical unsafety (rebase required).

## Churn classification

| Section | PRs | Driver category |
|---------|-----|-----------------|
| A: Header / docs | #726, #739, #761 | New mode and option documentation |
| B: Arg parsing | #616, #739, #761 | New flag + mode wiring |
| C: Authorship guard | #739 | New enforcement surface (issue #733) |
| D: Merge-gate pre-flight | #658, #968 | New bypass allowance + asymmetry fix |
| E: Solo-owner heuristic | — | Unchanged across all 7 PRs |
| F: Shape detection | #726 | New bypass shape (plain) |
| G: Mode implementations | #616, #658, #726, #761, #878, #968 | New shapes, correctness fixes, post-merge cleanup |

**Churn driver summary:** All 7 PRs were additive expansions or correctness fixes
for the script's role as the Claude ↔ human boundary for bypass merges. Four PRs
added new capabilities to that boundary (#658 clean-BEHIND allowance, #726 plain
shape, #739 authorship guard, #761 auto-plain mode). Two were correctness fixes
for edge cases discovered after initial implementation (#616 API reliability and
read-after-write, #968 gate-filter asymmetry). One was cross-cutting cleanup
added alongside a sibling feature (#878 issue claim release). None arose from
code-maintainability problems.

## Dedup search — restatements in `.claude/reference/` and `.claude/rules/`

Searched for downstream restatements of:
- Exit-code table (codes 0–8)
- Shape table (toggle vs plain)
- Solo-owner heuristic (CODEOWNERS parsing, admin count logic)

**Candidates examined:**

- **`admin-merge-auto-plain.md`** — the existing reference file for `--auto-plain`.
  Contains a focused exit-code table for the auto-plain caller contract, not a
  restatement of the full 9-exit-code header table. It is the _intended pointer
  target_ already registered in the catalog; it predates and motivates its own
  entries rather than restating the script. **Not a restatement.**

- **`cr-merge-gate.md` Step 1d** — invokes
  `admin-merge.sh <N> --auto-plain --ac-verified` as an operative instruction.
  This is policy the rule corpus owns, not a description of what the script does.
  **Not a restatement — operative instruction must stay in the corpus.**

- **`safety.md` §Authorship** — lists `admin-merge.sh` as one of three scripts
  enforcing the authorship guard. Descriptive pointer to the enforcement surface;
  does not restate exit codes, shapes, or heuristic logic.
  **Not a restatement.**

- **`authorship-guard.md`** — references `admin-merge.sh` as one of three
  shared-script fail-safes. Does not restate the script's contract beyond a
  single-line description. **Not a restatement.**

**Conclusion: no downstream restatements found. No dedup edits warranted.**

## Decision: KEEP — no extraction, no split, no dedup

The churn is legitimate: every PR was reactive to a new feature requirement,
a correctness gap, or an upstream behavior that the script's sole-boundary role
demanded it handle. The script has no independent, separately-evolving concerns
to split, no duplicated logic to extract (the solo-owner heuristic and the
clean-BEHIND check both delegate to sibling scripts already), and no downstream
restatements to replace with pointers.

The `admin-merge-auto-plain.md` reference file serves its intended purpose as
the detailed caller reference for `--auto-plain`, and `cr-merge-gate.md` Step 1d
correctly remains as an operative instruction in the auto-loaded corpus.

### What would change this verdict

A future PR that adds a second script implementing the same solo-owner heuristic,
or that restates the exit-code table in a rule file without pointing to the
script, would reopen the dedup case. A split might become warranted if the
`--execute` toggle path grew independent test coverage requirements that conflicted
with the `--auto-plain` path's strict no-protection-modification guarantee —
those share a single script today by design (the structural guarantee depends on
`auto-plain` being a separate branch in the same file).

## Related

- Issue #631 — clean-behind-check.sh introduction; the BEHIND allowance
- Issue #720 — plain vs toggle shape split
- Issue #733 — authorship guard (`pr-authorship.sh`)
- Issue #754 — `--auto-plain` mode; `.claude/reference/admin-merge-auto-plain.md`
- Issue #873 — issue claim release on merge
- Issue #947 — gate-filter asymmetry fix
- `.claude/scripts/clean-behind-check.sh` — the mechanical BEHIND-safety evaluator
- `.claude/scripts/pr-authorship.sh` — authorship gate delegated by this script
- `.claude/reference/admin-merge-auto-plain.md` — auto-plain caller contract
- `.claude/reference/authorship-guard.md` — authorship guard enforcement surface
