# merge-gate hotspot — diagnosis and extract-not-split decision

Reference for Issue #936 (`.claude/scripts/merge-gate.sh` churn hotspot). Not auto-loaded.

## The problem being read

`merge-gate.sh` was touched by 16 distinct merged PRs (#626, #659, #686, #727, #730, #739, #751,
#840, #849, #883, #891, #893, #907, #965, #972, #1001) — the highest-churn script file in the
repo when Issue #936 was filed.

The file is the single authoritative merge gate for all reviewer paths. Every consumer (`merge`,
`wrap`, `go-on`, `status`, `phase-c-merger`) reads its JSON output contract and must not change
when the internals are refactored. This junction nature explains some churn, but three additional
co-located concerns iterate independently and produce edit collisions:

| Concern | Location in merge-gate.sh | Churn driver |
|---------|---------------------------|--------------|
| CR/CodeAnt approval state machine | Lines 780–883 (~104 lines) | Reviewer-path changes (new guard, new bot) require editing identical CR and CA blocks separately |
| emit_json() 16-positional-parameter surface | Lines 245–270, 5 call sites | Each new output field requires updating the function signature and every call site |
| Freshness-verdict branching | CR/CA staleness block + BugBot freshness block | norm_ts comparison pattern repeated; future reviewer additions copy the pattern again |

## Decision: extract, not split

**Splitting merge-gate.sh into multiple scripts is rejected.**

Every consumer depends on a single `merge-gate.sh <PR>` invocation returning one JSON object.
A physical split would require consumers to orchestrate multiple script calls, reconcile partial
JSON, and handle failure modes across multiple processes. The merge gate's correctness is
audited by black-box tests (`merge-gate-*.test.sh`) that call the script end-to-end; a split
would require re-architecting all of them.

This follows the same extract-not-split verdict as:
- `fixpr/SKILL.md` hotspot (#788) — extracted deterministic concerns into `.claude/scripts/*.sh`
- `pr-state.sh` hotspot (#980) — extracted two pure jq programs, kept the public CLI
- `subagent-orchestration.md` hotspot (#814) — extracted Phase A/B/C descriptions to canonical owners

## Concrete remedy (Issue #936, implemented in the PR that closes it)

One targeted extraction, zero behavior change:

### 1. CR/CodeAnt approval state machine → `_fetch_bot_approvals` local function

The near-identical CR and CodeAnt approval blocks (jq queries, retraction logic, stale-approval
guard, substance check) were extracted into one parameterized local function `_fetch_bot_approvals`
defined inside merge-gate.sh. The function accepts `<PREFIX> <login>` (e.g. `CR "coderabbitai[bot]"`)
and sets the correct global variables using `eval` for dynamic variable names. bash 3.2 compatible:
no namerefs, no associative arrays.

The following derivations are **deliberately kept in the calling scope**, not the function:

| Variable | Reason kept in main body |
|----------|--------------------------|
| `CR_STALE_REDEEMED` / `CA_STALE_REDEEMED` | `ts-normalizer-parity.test.sh` pins the exact `external_evidence_ok` condition that precedes the `=true` assignment |
| `CR_APPROVAL_STALE_BLOCKING` / `CA_APPROVAL_STALE_BLOCKING` | Same test pins the condition (`$_APPROVAL_STALE == true && $_STALE_REDEEMED == false`) preceding the `=true` assignment |
| `CR_APPROVAL_VALID` / `CA_APPROVAL_VALID` / `CR_HOLLOW` / `CA_HOLLOW` | Same test extracts the guard block starting at `CR_APPROVAL_VALID=false` and verifies nesting order of `_STALE_BLOCKING` and `_SUBSTANTIVE` checks |

**Net change**: the duplicated 104-line CR+CA block shrinks to two function calls; the
parameterized function body is ~60 lines. Future reviewer-path changes (new bot, revised stale
guard, updated substance check) require editing only the function, not two separate blocks.

### Why emit_json() and freshness branching were not changed

`emit_json()` uses 16 positional parameters across 5 call sites. Replacing positional parameters
with a named-variable or associative-array approach requires bash 4+ for associative arrays;
a global-variable-based approach saves few call-site lines and weakens encapsulation. The current
16-param form is verbose but correct and covers the full JSON contract without risk of field
ordering or key-name drift. Left unchanged.

The freshness-verdict branching (norm_ts comparisons in the CR/CA and BugBot blocks) was folded
into `_fetch_bot_approvals` for the CR/CA cases. The BugBot block uses norm_ts in a different
structural context (the result feeds MISSING[] entries directly, not bot-specific variables) and
the Greptile block uses an inline jq `def canon_ts` rather than bash norm_ts — these two are not
unified to avoid false parity. Left as-is.

## What was explicitly preserved

- JSON output contract: `.met`, `.reviewer`, `.path`, `.missing[]`, `.head_sha`, `.ci_status`,
  `.merge_state`, `.mergeable`, `.review_decision`, `.code_owner_bots`, `.human_changes_requested`,
  `.stale_bot_changes_requested_count`, `.unresolved_thread_count`, `.primary_review_met`,
  `.authorship`, `.review_evidence` — byte-identical across all paths
- All documented variable names reachable in merge-gate.sh source: `CR_APPROVAL_VALID`,
  `CA_APPROVAL_VALID`, `CR_APPROVAL_STALE_BLOCKING`, `CA_APPROVAL_STALE_BLOCKING`,
  `CR_STALE_REDEEMED`, `CA_STALE_REDEEMED`, `CR_PATH_APPROVED_ON_HEAD` — unchanged
- Boolean formulas for the validity block, stale-blocking derivation, and redemption channel:
  unchanged operand count, operand order, and guard nesting — `ts-normalizer-parity.test.sh`
  validates all of them and was not modified
- Zero-initialization block (lines 758–776): unchanged, needed so the cr) MISSING section
  works correctly when the CR/CA guard does not fire
- All `if [[ "$REVIEWER" == "cr" || "$REVIEWER" == "bugbot" ]]; then` guard structure: unchanged

## Related

- Issue #836 — stale-approval guard (the primary security invariant preserved by structural tests)
- Issue #875 — review-substance guard (substance_ok call extracted into function)
- Issue #876 — stale-approval redemption (external_evidence_ok channel preserved in main scope)
- Issue #865 — shared CR/CA block for bugbot path
- Issue #788 — fixpr hotspot, structural precedent for local extraction
- Issue #980 — pr-state hotspot, precedent for keeping public CLI while extracting internals
- `.claude/scripts/tests/ts-normalizer-parity.test.sh` — structural test that pins the preserved formulas
- `.claude/reference/merge-gate-reviewer-paths.md` — authoritative per-path semantics
