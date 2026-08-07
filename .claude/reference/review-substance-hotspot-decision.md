<!-- churn-hotspot: .claude/scripts/review-substance.sh -->
# `review-substance.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #996 (`.claude/scripts/review-substance.sh` churn hotspot). Not auto-loaded.

> **Disambiguation.** A sibling record, `.claude/reference/review-substance-evidence-hotspot-decision.md`,
> adjudicates the *evidence doc* (`.claude/reference/review-substance-evidence.md`) filed in Issue #1029.
> That record covers why the living-trace log is kept whole. This record covers the *evaluator script* itself.
> The two share churn classes and a KEEP verdict; they address different artifacts and different structural
> questions (script modularization vs. evidence-doc splitting). Cross-reference below where the two diagnoses
> converge.

## The problem being read

`.claude/scripts/review-substance.sh` was touched by 7 distinct merged PRs since
2026-07-21: #883, #891, #896, #911, #923, #951, and #972.

The script is the pure evaluator for hollow-approval detection (Issue #875). It
accepts a JSON payload on stdin (reviews + PR/issue comments for one PR) and
emits a JSON object reporting whether each bot's APPROVED represents a real review.
It has no network calls; callers (`merge-gate.sh`, `escalate-review.sh`) pass the
payloads they fetched. The churn window begins with the script's birth and runs
through the first dozen days of active hollow-approval defense.

## Functional sections

The 850-line script is organised around seven logical areas sharing boundary lines
(helper defs, jq `as` bindings, etc.); ranges are approximate.

| Section | Lines (approx) | Purpose |
|---------|----------------|---------|
| A — Shell header / contract | 1–100 | Purpose, signal descriptions, stdin/stdout schema, flag docs |
| B — Arg parsing / validation | 101–225 | `--min-chars`, `--reviewers`, `--corroborators`, `--help`, input guard |
| C — jq `def` helpers | 226–270 | `canon_ts`, `sha_tokens`, `strip_echoed` |
| D — Token admission logic | 271–450 | Three SHA-admission rules, UUID stripping, fence stripping |
| E — Per-reviewer signal loop | 451–680 | Temporal inversion, capability failure, self-report mismatch, substance |
| F — Output assembly | 681–760 | `substantive[]`, `hollow[]`, `mismatched[]`, `inverted[]`, `corroborating[]` |
| G — Caller shell / exit | 761–850 | `OUT=`, final stdout, stderr discounts announcement, exit 0 |

## Churn attribution — per-section evidence

### PR #883 (2026-08-01) — Sections A–G: initial creation

`fix(#875): stop counting hollow bot approvals as review coverage`

This PR **created the file from scratch**, implementing the complete signal set for
Issue #875:

- **Section A:** shell header documenting all five discriminators (temporal inversion,
  capability failure, self-report mismatch, substance, seconds-after-push), the full
  stdin/stdout schema, the `--min-chars`/`--reviewers`/`--corroborators` flag contract,
  and the O(n²) bash-substitution performance note.
- **Section C:** initial `canon_ts` jq def — strips UTC zone suffix and fractional
  seconds, folds spellings to `Z`. Deliberately different from `norm_ts` in
  `merge-gate.sh` (which keeps fractional seconds); the difference is safe because
  every timestamp `review-substance.sh` compares passes through this one function
  and is never compared against a `merge-gate.sh` value. The divergence is noted
  inline.
- **Section D:** initial token-admission rule (form rule only: `\b[0-9a-f]{7,40}\b`
  with at least one `a-f` letter); initial fence stripping (closed backtick fences
  only, `m` flag); substance pooling across a bot's multiple `APPROVED` reviews
  on the same SHA.
- **Section E:** full five-signal evaluation loop with `external_evidence_on_head`
  as the shared clearing term for signals 1 and 2.
- **Section F/G:** `substantive[]`, `hollow[]`, `mismatched[]`, `inverted[]`,
  `capability_failed[]`, `corroborating[]` output fields; stderr discount
  announcement on every discounted approval.

**Driver:** Issue #875 — the hollow approval problem. `merge-gate.sh` had counted
any bot `APPROVED` whose `commit_id` matched HEAD as review coverage. A series of
real merges showed those approvals were routinely empty-bodied, posted seconds
after a push, sometimes timestamped before the bot announced it had started
reviewing, and once after the bot said it had no review subscription. PR #883
introduced this pure evaluator as the solution.

---

### PR #891 (2026-08-01) — Section C: comment update for `canon_ts` divergence

`fix(#885): make gate/escalation timestamp drift fail in CI, not in review`

PR #891 introduced `lib/ts-normalizer.sh` (the shared bash `norm_ts` function for
`merge-gate.sh` and `escalate-review.sh`) and `tests/ts-normalizer-parity.test.sh`.
The change to `review-substance.sh` was **comment-only**: the inline comment on the
`canon_ts` def was extended to name `ts-normalizer-parity.test.sh` explicitly and
state that the test **pins the `canon_ts` divergence**, so a future "unify all three"
refactor that erases the deliberate difference will fail in CI rather than silently
corrupting ordering.

**Driver:** Issue #885 — two timestamp-ordering bugs on PR #883 (canon_ts dropped
fractional seconds while norm_ts kept them; a subsequent fix normalised `+0000` on
one side only). The parity test extracts the real jq def from the shipped file at
runtime and asserts byte-for-byte agreement with the bash library across the full
spelling matrix. The `review-substance.sh` touch was the documentation side of
establishing that contract: pinning not only the shared rule but the *deliberate
divergence* from it.

---

### PR #896 (2026-08-01) — Sections A, C, D: three SHA-admission rules

`fix(#894): believe an all-decimal short SHA, without believing every number`

Added two new admission rules to `sha_tokens` (Section C/D) and updated Section A:

- **Rule 2 — IDENTITY:** an all-decimal `\b[0-9]{7,40}\b` run that prefix-matches
  or is prefix-matched by the known HEAD SHA. 15 of the last 431 commits on the
  repo's `main` at the time of writing (3.5%) had all-decimal SHAs; rule 1 alone
  discarded them, making `status_comment_names_head` structurally false and blocking
  the Issue #876 stale-approval redemption path entirely.
- **Rule 3 — CODE SPAN:** an all-decimal run that is a complete inline code span
  (`` `1234567` ``). Rule 3 exists only for `self_report_mismatch` detection: without
  it, a rubber stamp whose status comment named an older all-decimal SHA yielded no
  tokens and therefore couldn't register as a self-report contradiction. Rule 3 reads
  fence-stripped text only (not the raw body), so quoted code containing numeric
  literals inside fences cannot manufacture false self-reports.
- **Section A** updated to describe the three rules and document the load-bearing
  argument that rule 3 cannot weaken the gate (any token admitted by rule 3 but not
  rules 1–2 is, by construction, an all-decimal run that does not prefix-match HEAD —
  it can only withhold coverage, never grant it).

**Driver:** Issue #894 — all-decimal short-SHA wedge. The evaluator needed a safe
way to believe a genuine all-decimal SHA without believing every date, count, or
identifier that happens to be numeric.

---

### PR #911 (2026-08-01) — Sections A, D: fence-strip extension

`fix(#897): extend rule-3 fence strip to tilde, indented, and unclosed fences`

Extended the fence-stripping step in Section D from closed backtick fences only to
four shapes, in order:

1. Closed `` ``` `` fences (lazy — stops at first closing fence)
2. Closed `~~~` fences (same discipline)
3. Unclosed `` ``` `` opener → end-of-body (runs after closed fences so it doesn't
   consume content between a pair)
4. Four-space-indented lines (`\n    [^\n]*`)

Updated Section A to document that rule 3 (code-span) reads fence-stripped text,
so a decimal run quoted inside a tilde fence, indented block, or unclosed backtick
opener does not become a self-report.

Also noted in Section A: the jq flag is `m` (multiline), not `s` (single-line) — a
correctness note for maintainers because the two flags give different results for
fenced content spanning multiple lines.

**Driver:** Issue #897 — CodeRabbit walkthroughs include tilde fences, indented code
blocks, and occasionally unclosed fences; without stripping them, numeric literals
inside those blocks registered as self-report candidates under rule 3.

---

### PR #923 (2026-08-02) — Section D: UUID-embedded hex fragment exclusion

`fix(#917): exclude UUID-embedded hex fragments from SHA-candidate extraction`

Added a UUID-stripping step in Section D: before applying rule 1 (hex form),
replace `8-4-4-4-12` hyphenated hex UUIDs (with identifier-glued variants handled
via a no-preceding-hex-digit lookbehind) with a space in the comment body. Added
`as $unuuid` binding; rule 1 reads `$unuuid` while rules 2–3 still read `$btxt`
(UUIDs never match HEAD's identity, and backtick-wrapped all-decimal UUIDs don't
exist). Documented that a UUID sitting between two genuine tokens is not stripped
to empty, so genuine SHA tokens in the same comment remain discoverable.

Updated Section D comments to state that rule 1 is the only rule that reads
UUID-stripped text, and why: rules 2–3 are anchored on HEAD's identity or on
backtick-only decimal runs, neither of which a hyphenated hex UUID can satisfy.

**Driver:** Issue #917 — CodeRabbit embeds an invocation UUID in HTML comments
(`<!-- request id 9f69125b-29d9-47d4-bf8f-8b5df9dcb5a6 -->`); `\b` treats
hyphens as non-word boundaries, so a UUID split into five hex segments of lengths
8, 4, 4, 4, and 12, all satisfying rule 1. A UUID-only status comment became the
reviewer's most-recent SHA-naming post, masking the actual walkthrough.

---

### PR #951 (2026-08-02) — Sections A, C, D, E: echo/quote stripping

`fix(#933): a reviewer quoting the author's SHA no longer proves it read HEAD`

Added `strip_echoed` jq def to Section C and the corresponding `as $btxt`
pre-processing step in Section D. Changed all downstream signal computations in
Sections D–E to read `$btxt` (echo-stripped body) rather than the raw body:

- **`strip_echoed`:** processes a body line by line using a stable index rather than
  a content scan (edit-aware semantics: a bot can edit an echo into a comment it
  opened before the author wrote the line). Lines identified as echo/quote — defined
  as any line beginning with `>` (blockquote) or matching the PR #929 implicit echo
  pattern (reviewer reproducing the author's trigger prose verbatim with no quote
  marker) — are dropped. Fence delimiter lines (`` ``` ``, `~~~`) inside quotes are
  truncated to their delimiter run rather than dropped outright, so a quoted fence
  line does not destroy the paired-delimiter structure that the fence-stripping step
  in Section D depends on.
- **Section A** updated to explain why "strip every blockquote line" is insufficient
  (the PR #929 echo carried no `>` at all), and why dropping delimiter lines is
  unsafe.

**Driver:** Issue #933 — the PR #929 shape: a reviewer echoed the author's SHA in
its summary comment ("`HEAD is 5acd1e2`" reproduced verbatim with no `>`), making
`status_comment_names_head` true on the strength of the author's words rather than
the reviewer's own observation. Dropping echoed content before any signal computation
ensures that only a reviewer's own references to HEAD count.

---

### PR #972 (2026-08-03) — Sections A, E, F: descriptive non-SHA evidence

`fix(review): recognize descriptive non-SHA evidence`

Added `$descriptive_ev` signal in Section E and `descriptive_evidence_on_head`
output field in Section F:

- **`$descriptive_ev`:** true when the reviewer's conversation comments (post-push,
  in the current review round, at or after the run-start marker) collectively reach
  `>= min_chars` without a capability-failure notice. Operationally: a long
  descriptive summary or walkthrough comment that does not name HEAD's SHA directly
  but demonstrably represents a review of this commit.
- `$descriptive_ev` is ORed only into `$ext_substantive` — the external-evidence
  branch of the substance check. It never enters `$inv_evidence` (temporal inversion
  clearing) or `$cap_ev` (capability failure clearing), so a descriptive comment
  does not redeem a temporally inverted or capability-failed approval; those remain
  disqualified regardless.
- **Section A** updated to list `descriptive_evidence_on_head` in the output schema
  and describe the new substance shape.

**Driver:** Issue #927 — CodeRabbit walkthroughs sometimes describe the changes
without naming the HEAD SHA explicitly (e.g., a `## Review summary for this PR`
comment that refers to the changes by description rather than by commit ID).
Without this shape, such walkthroughs scored `$ext_substantive = false` even when
the body and inline comments alone cleared the `min_chars` threshold, blocking the
gate on genuine reviews.

---

## Churn classification

| Section | PRs | Driver category |
|---------|-----|-----------------|
| A: Header / contract | #883, #896, #911, #951, #972 | Initial creation + per-fix output-field and flag documentation |
| B: Arg parsing | #883 | Initial creation |
| C: jq `def` helpers | #883, #891, #896, #951 | New helper defs + comment-only parity annotation |
| D: Token admission / preprocessing | #883, #896, #911, #923, #951 | Bug-fix additions to the SHA-token and fence-strip logic |
| E: Per-reviewer signal loop | #883, #951, #972 | Initial creation + echo-filtering + descriptive evidence |
| F: Output assembly | #883, #972 | Initial creation + `descriptive_evidence_on_head` field |
| G: Caller shell / exit | #883 | Initial creation only |

**Churn driver summary:** PR #883 is the birth of the file (all sections). Every
subsequent PR added a targeted fix to one or two signal-adjacent sections (C, D, or
E) in response to a real bypass shape discovered during active hollow-approval
defense. No two PRs touched the same bug surface. PR #891 is comment-only. No PR
restructured the file or altered the exit-code/flag contract (Section B, G).

## Verification of structural claims

### Claim 1 — verbatim consumers

`merge-gate.sh` calls `review-substance.sh` as a subprocess at line 517–539
(Section "Review substance (issue #875) — delegated to review-substance.sh") and
reads named output fields including `.reviewers[<login>].counts_as_coverage`,
`.disqualified_by`, `.external_evidence_on_head`, `.status_comment_shas`, and the
top-level `.substantive[]`, `.hollow[]`, `.mismatched[]`, `.inverted[]`,
`.capability_failed[]`, `.corroborating[]` arrays. It discovers the script by
relative path from its own `dirname`.

`escalate-review.sh` calls `review-substance.sh` at line 252–275 for the same
purpose: verifying that a gate-already-met APPROVED on HEAD is substantive before
reporting `gate_met`. It reads the same named output fields.

Both callers depend verbatim on the script's stdin/stdout schema and named fields.
A rename, split, or interface change would break both.

### Claim 2 — `canon_ts` divergence pinned by `ts-normalizer-parity.test.sh`

`tests/ts-normalizer-parity.test.sh` (introduced in PR #891, Issue #885) explicitly
states in its header:

> **ALSO PINNED**
> `review-substance.sh`'s `canon_ts` is deliberately DIFFERENT (drops the
> fraction, folds the UTC spellings onto "Z"). That is safe because every
> timestamp it compares passes through that one function. A future "unify all
> three" refactor would silently change its ordering, so the divergence is
> asserted rather than merely commented.

The test extracts the `canon_ts` def block from `review-substance.sh` at runtime and
asserts that it *does not* agree with `norm_ts` from `lib/ts-normalizer.sh` on
fractional inputs. Any edit that unifies the two implementations will fail this test
before reaching code review.

### Claim 3 — jq has no module convention in this repo

No `.jq` module files exist anywhere in the repo. The only shared jq logic in scope
for this script — `norm_ts` / `canon_ts` — is implemented as a bash function sourced
in shell callers and an inline jq `def` inside single-quoted jq programs. The parity
test is the enforcement mechanism for keeping those in step. There is no `jq -f`
convention to extend.

### Claim 4 — churn PRs map to named issues

| PR | Issue | Verified |
|----|-------|---------|
| #883 | #875 (hollow approvals) | PR title `fix(#875)` |
| #891 | #885 (timestamp drift) | PR title `fix(#885)` |
| #896 | #894 (all-decimal SHA) | PR title `fix(#894)` |
| #911 | #897 (fence-strip extension) | PR title `fix(#897)` |
| #923 | #917 (UUID fragments) | PR title `fix(#917)` |
| #951 | #933 (echo/quote stripping) | PR title `fix(#933)` |
| #972 | #927 (descriptive evidence) | PR title `fix(review)` / issue number in diff comment |

The CR plan named issues #933, #927, and #894 as confirmed signal-logic additions;
all three confirmed.

## Assessment of structural options

### Option considered: extract `sha_tokens`, `strip_echoed`, `canon_ts` into a shared jq file

**Blocked by structural constraint.** There is no jq module convention in this repo,
and the file is a single-quoted jq program called via a bash heredoc (`jq -c '…'`).
The `canon_ts` divergence from `lib/ts-normalizer.sh` is deliberately maintained and
pinned by `ts-normalizer-parity.test.sh`; unification would silently corrupt ordering
for timestamps with fractional seconds. The only extraction path would be a bash
lib/ file wrapping the jq call, which would change the delivery mechanism from a
pure evaluator to a shell script with sourcing dependencies — adding complexity
without reducing the measured churn surface (all five churn drivers touched the jq
program body directly, not the calling shell wrapper).

### Option considered: split into separate signal scripts (one per discriminator)

**Structural incompatibility.** The five signals share state: `$ext_substantive`,
`$inv_evidence`, `$cap_ev`, `$descriptive_ev`, and the per-reviewer `$ridx`,
`$iidx`, `$cidx` indexes. Splitting by signal would require inter-process
serialization of those intermediate values, which currently live as jq `as`
bindings inside a single program. No PR in the churn window touched the same
signal twice; each addition was orthogonal. There is no duplication to remove.

### Option considered: documentation dedup of triple-restated rationale

`review-substance.sh`'s header comments, the inline jq comments in the signal loop,
and `.claude/reference/review-substance-evidence.md` each describe aspects of the
evaluator's design. The CR plan notes this and records it as a documented future
option.

**Declined in this PR.** The rationale in the header and inline comments is written
inside a jq single-quoted program where apostrophes would break quoting — it
annotates the exact code it accompanies and cannot be moved to an external file.
The evidence doc is a living trace log for bypass shapes, not a restatement of the
script's internal comments; the two serve different readers (inline comments: a
future maintainer editing the jq program; evidence doc: a future reviewer trying
to understand why a specific signal exists). The measured churn driver was
logic fixes, not documentation edits, so dedup would not reduce the historical
churn count. This option is recorded here rather than acted on.

## Cross-reference with companion adjudications

This adjudication shares structural conclusions with three companion records:

- **`review-substance-evidence-hotspot-decision.md`** (Issue #1029, PR #1030) —
  adjudicates the evidence doc itself. Same KEEP verdict, same diagnosis of
  purposeful accumulation. The two files address different artifacts: the evidence
  doc accumulates bypass traces and design-reasoning prose; this script contains
  the runtime jq evaluator. Keeping either would not require keeping the other, but
  the shared churn driver (sequential bypass-shape discoveries) is consistent.

- **`merge-gate-review-substance-test-hotspot-decision.md`** (Issue #1014, PR #1026)
  — adjudicates the companion test file. Reached KEEP on the grounds of purposeful
  regression accumulation with no companion doing overlapping work. The same pattern
  applies here: the script and its test accumulate independent per-fix content in
  parallel, driven by the same sequence of bypass discoveries.

- **`escalate-review-hotspot-decision.md`** (Issue #977) — adjudicates
  `escalate-review.sh`, one of the two verbatim consumers. KEEP verdict; 7 of 9
  PRs in that window touched code unique to that script. The shared evaluator
  (`review-substance.sh`) is referenced there as an independent piece with its own
  churn surface.

## Decision: KEEP — no extraction, no split, no dedup

**Verdict: KEEP `review-substance.sh` unchanged.**

All 7 PRs were additive, non-conflicting fixes to the hollow-approval detection
logic. The file cannot be modularized via jq modules (no convention exists), the
signal loop shares intermediate state that prohibits a signal-per-script split,
and the `canon_ts` divergence is deliberately maintained and CI-enforced. The
stdin/stdout schema, all flags, and all exit codes are consumed verbatim by two
callers.

This decision is intentionally reference-only. `review-substance.sh` is
byte-identical at adjudication time.

### What would change this verdict

A future PR that introduces a second script duplicating the SHA-token admission
logic or the echo-stripping logic, or that restates the signal conditions in a rule
file without pointing to this evaluator, would reopen the dedup case. A split into
separate signal scripts would become viable only if a jq module convention were
established in this repo and the inter-signal state were cleanly separable — neither
condition holds today.

## Related

- Issue #875 — hollow bot approvals; original `review-substance.sh` creation (PR #883)
- Issue #885 — timestamp drift between `norm_ts` and `canon_ts`; parity test (PR #891)
- Issue #894 — all-decimal short-SHA wedge (PR #896)
- Issue #897 — fence-strip extension to tilde/indented/unclosed (PR #911)
- Issue #917 — UUID-embedded hex fragment exclusion (PR #923)
- Issue #933 — echo/quote stripping (PR #951)
- Issue #927 — descriptive non-SHA evidence (PR #972)
- `.claude/scripts/merge-gate.sh` — primary consumer (lines 517–539)
- `.claude/scripts/escalate-review.sh` — secondary consumer (lines 252–275)
- `tests/ts-normalizer-parity.test.sh` — pins `canon_ts` divergence
- `.claude/reference/review-substance-evidence.md` — living bypass-trace log
- `.claude/reference/review-substance-evidence-hotspot-decision.md` — companion adjudication (Issue #1029)
- `.claude/reference/merge-gate-review-substance-test-hotspot-decision.md` — test file adjudication (Issue #1014)
- `.claude/reference/escalate-review-hotspot-decision.md` — consumer-script adjudication (Issue #977)
