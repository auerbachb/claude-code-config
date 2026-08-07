# `reply-thread.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #1097 (`.claude/scripts/reply-thread.sh` churn hotspot). Not auto-loaded.

## The problem being read

`.claude/scripts/reply-thread.sh` was touched by 3 distinct merged PRs since
2026-07-24: #798, #904, #1001.

The script is the single authoritative implementation for posting reviewer-aware
replies to PR review threads (C-09 in `script-extraction-audit.md`). It handles
inline replies, PR-level fallback, and reviewer-specific `@mention` rules for
all four bot reviewer modes (CR, BugBot, Greptile, CodeAnt).

## Functional sections

The 329-line script is organized around six functional anchors:

| Section | Lines (approx) | Purpose |
|---------|----------------|---------|
| A — Header / docs | 1–58 | Reviewer modes, usage, exit codes |
| B — Arg parsing / validation | 59–148 | Flag parsing, reviewer/comment/body validation |
| C — Body transformation | 150–217 | `strip_standalone_token()`, per-reviewer `@mention` rules |
| D — Owner/repo resolution | 219–236 | `gh repo view --json owner,name` |
| E — Inline reply | 237–278 | `pulls/comments/{id}/replies` POST + success/failure classification |
| F — PR-comment fallback | 279–329 | `gh pr comment` POST + URL extraction + exit-code contract |

## Churn attribution — per-section evidence

### PR #798 (Issue #772) — Sections A, B, C

Added `codeant` as a fourth `--reviewer` value. Changed:
- Section A: new `codeant` entry in the header comment describing `@codeant-ai` stripping; updated Usage line
- Section B: extended the `case "$REVIEWER"` accept-list and the `--reviewer requires a value` error message
- Section C: added `codeant)` case calling `strip_standalone_token` with the `@codeant-ai` hyphen-literal pattern; extended the blank-body guard's reviewer check; extended the `sed` trim block's reviewer check

**Driver:** New reviewer (CodeAnt) added to the review chain (`cr-github-review.md`). The strip rule mirrors BugBot and Greptile — all three require plain-text replies to avoid triggering paid re-reviews or rate-limited re-invocations. This was purely additive: no existing behavior changed.

### PR #904 (Issue #884) — Sections A, F

Fixed exit code on successful PR-level fallback: changed `exit 1` to `exit 0`; added a stderr note so callers that want to detect the fallback path can do so without breaking `&&`-chains. Updated the header exit-code table (exit 1 now unused/reserved). Extended the test suite with 6 new cases including a revert-check regression test.

**Driver:** Correctness fix for a known bug where `&&`-chained callers (e.g., `/fixpr`) treated a successfully posted fallback reply as failure, causing duplicate comments. The fallback path had always posted correctly; the error was in the exit code. Per-section: Section F (fallback reply success path) changed; Section A (exit code 1 annotation) updated.

### PR #1001 (Issue #1000) — Section F

Added a `<!-- review-comment-id:$COMMENT_ID -->` HTML comment to the fallback body, so the fallback now posts:

```
<!-- review-comment-id:$COMMENT_ID -->
$BODY
```

**Driver:** Provenance preservation. When GitHub cannot accept an inline reply, the hidden marker lets downstream audit/gate tooling (`merge-gate.sh` and related consumers) prove which finding a PR-level fallback addressed, without cluttering the visible prose. This was part of the larger Greptile zero-P0 reuse work (Issue #1000), which needed reliable evidence that a fix addressed a specific reviewer finding even when the inline reply endpoint returned 404. Section F only; no other sections changed.

## Churn classification

| Section | PRs | Driver category |
|---------|-----|-----------------|
| A: Header / docs | #798, #904 | New reviewer mode docs; exit-code correction |
| B: Arg parsing / validation | #798 | New reviewer value wired in |
| C: Body transformation | #798 | New strip rule for CodeAnt |
| D: Owner/repo resolution | — | Unchanged across all 3 PRs |
| E: Inline reply | — | Unchanged across all 3 PRs |
| F: PR-comment fallback | #904, #1001 | Exit-code correctness fix; provenance marker |

**Churn driver summary:** All 3 PRs were legitimate. PR #798 was a new-feature
addition (CodeAnt reviewer support). PR #904 was a correctness fix for a
concrete duplication bug traceable to a specific incident. PR #1001 was a
targeted enhancement to the fallback path that enabled a separate feature
(Greptile round reuse). Sections A and F each appear in two PRs, but the
changes within each section were non-overlapping: Section A gained new-reviewer
docs (PR #798) then an exit-code annotation correction (PR #904); Section F
gained the exit-code fix (PR #904) then the provenance marker (PR #1001).
No two PRs modified the same lines of logic within any section.

## Duplication verification — owner/repo resolution block

The CodeRabbit plan proposes extracting the `gh repo view --json owner,name`
owner/repo resolution block shared with `resolve-review-threads.sh`. Before
extracting, the task requires byte-near-identical confirmation. Side-by-side
inspection:

**`reply-thread.sh` (Section D, lines 222–236):**
- Stderr captured via temp file: `REPO_ERR=$(mktemp -t reply-thread-repo.XXXXXX)` with `2>"$REPO_ERR"`
- `jq -er` — the `-e` flag causes jq to exit non-zero if the result is null/false/missing, providing implicit null detection
- Checks `[[ -z "$OWNER" || -z "$REPO" ]]` as a belt-and-suspenders after `jq -er`
- Resolution failure exits with code **5**

**`resolve-review-threads.sh` (lines 187–196):**
- Stderr merged to stdout: `2>&1`, so the error text is captured in the JSON variable
- `jq -r` — does not exit on null; produces the literal string `"null"` for missing fields
- Checks `[[ -z "$OWNER" || -z "$REPO" || "$OWNER" == "null" || "$REPO" == "null" ]]` to catch the `"null"` string case that `jq -r` would otherwise pass through
- Resolution failure exits with code **4**

**Differences:**

| Attribute | reply-thread.sh | resolve-review-threads.sh |
|-----------|-----------------|---------------------------|
| Stderr capture | temp file (`mktemp`, `2>"$REPO_ERR"`) | merged to stdout (`2>&1`) |
| jq flag | `-er` (exits non-zero on null) | `-r` (returns string `"null"`) |
| Null detection | `jq -er` implicit + `[[ -z ]]` | `[[ == "null" ]]` explicit |
| Failure exit code | 5 | 4 |

These are different implementations of the same purpose. Extraction would
require choosing a canonical form, which would change at least one consumer's
behavior (exit code, stderr handling, or jq null semantics). That is out of
scope for a hotspot adjudication, which must preserve all exit-code contracts
without modification.

**Duplication verification result: NOT byte-near-identical. Extraction not warranted.**

## Decision: KEEP — no extraction, no split, no dedup

All 3 PRs were legitimate additions to a script that owns a single, cohesive
responsibility. The churn was reactive (new reviewer type, correctness fix,
provenance enhancement) rather than structural. The script is 329 lines; none
of its sections are independently deployable concerns.

The owner/repo resolution block is not a valid extraction target because the
two instances in `reply-thread.sh` and `resolve-review-threads.sh` differ in
implementation. Extracting without normalizing behavior would produce a lib that
silently changes one consumer's error-handling path. The correct path for
extraction (if pursued in a future PR) is: first converge the two blocks to
identical behavior, then extract — two distinct steps, each with its own PR.

The reviewer-transformation and fallback logic are tightly coupled to
`reply-thread.sh`'s public contract and have no meaningful duplication
elsewhere. The `strip_standalone_token` helper is an internal implementation
detail of the transformation section.

### What would change this verdict

1. **Converged blocks:** If a cleanup PR first converges the two `gh repo view`
   resolution blocks to byte-identical implementations (same jq flags, same
   stderr handling, same error-exit code), extraction into
   `lib/owner-repo-resolver.sh` becomes viable as a second step.
2. **New reviewer at 3+ PRs:** Adding a third new reviewer mode after CodeAnt
   would touch Sections A, B, C again. At that point, a table-driven approach
   in Section C could reduce per-mode churn — each mode would be one row, not
   four scattered changes.
3. **Fallback behavior divergence:** If the PR-comment fallback acquires
   independent test requirements that conflict with the inline path, a dedicated
   fallback helper could be considered.

## Related

- Issue #772 — CodeAnt reviewer mode (PR #798)
- Issue #884 — fallback exit-code fix (PR #904); the known bug where the fallback posted successfully but the old code exited 1, causing `&&`-chained callers (e.g., `/fixpr`) to treat a successful post as failure and post duplicate comments — the fix changed the exit code to 0 (see memory `feedback_reply_thread_fallback_exit.md`)
- Issue #1000 — Greptile zero-P0 round reuse; fallback provenance marker (PR #1001)
- `script-extraction-audit.md` entry C-09 — origin record for `reply-thread.sh` (Issue #282)
- `.claude/scripts/reply-thread.sh` — the subject file; exit-code contract authoritative in `--help`
- `.claude/scripts/resolve-review-threads.sh` — the other consumer of the similar (not identical) owner/repo resolution block
- `.claude/reference/greptile-reply-format.md` — reply conventions for Greptile threads (the behavioral spec this script enforces)
- `.claude/rules/cr-github-review.md` "Processing CR Feedback" step 3 — the CR reply protocol
- `.claude/rules/bugbot.md` and `.claude/rules/greptile.md` — strip-token rationale for BugBot/Greptile modes
- `.claude/reference/codeant-graphite-supplemental.md` — CodeAnt reply conventions (plain-text, rate-limited)
