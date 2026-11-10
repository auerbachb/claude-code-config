# Verification Evidence Patterns

On-demand reference for **evidence-before-claims** discipline in this repo's
workflow. Phase A/B/C exit reports and the merge gate's AC verification
(`cr-merge-gate.md` Step 2 via `ac-checkboxes.sh`) already require proof; this
document distills the *judgment* — which command proves
which claim — adapted from [obra/superpowers
`verification-before-completion`](https://github.com/obra/superpowers/tree/main/skills/verification-before-completion)
(harvested via issue #417).

The superpowers plugin skill remains the runtime source for generic
verification discipline. Read this when writing exit reports, ticking AC
checkboxes, or claiming merge readiness in *this* repo.

Not auto-loaded.

## Iron law (repo-specific)

```
NO COMPLETION / MERGE / AC CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE IN THIS MESSAGE
```

If you have not run the proving command in the current turn, you cannot claim the
outcome — even if a prior turn passed, a subagent reported success, or CI
"should" be green after a push.

## Gate function

Before any status claim (`done`, `passing`, `clean`, `merge-ready`, `AC met`):

1. **Identify** — what command or script output proves this claim in *our* stack?
2. **Run** — execute the full command fresh (not a partial grep, not memory).
3. **Read** — exit code + full relevant output (counts, SHAs, verdict lines).
4. **Verify** — does output actually support the claim?
5. **Claim with evidence** — quote the decisive lines or JSON fields.

Skip a step = the claim is unsupported.

## Claim → evidence map (our workflow)

| Claim | Proving command / artifact | Not sufficient |
|-------|---------------------------|----------------|
| Local CR clean | `coderabbit review --agent` → zero findings on current diff | Earlier clean run before new edits |
| Rule budget OK | `{ cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } \| wc -w` within budget; `rule-lint.sh` pass | "Looks short" |
| Hook tests pass | `for f in .claude/hooks/tests/*.test.sh; do bash "$f"; done` + `python3 -m unittest discover -s tests -p 'test_*.py'` | Single test file only |
| CI green on PR SHA | `bash .claude/scripts/ci-status.sh <PR>` or `merge-gate.sh` JSON with `ci_status.failing == 0` and `ci_status.in_progress == 0` on current HEAD | Last run before push |
| Review gate met | `bash .claude/scripts/merge-gate.sh <PR>` exit 0 + quoted verdict JSON (omit `--reviewer` — auto-detects cr/bugbot/greptile path) | Stale APPROVED on old SHA |
| AC checkboxes honest | `ac-checkboxes.sh --extract` matches reality; only `--tick` after verification | Ticking from intent |
| Phase A/B complete | Exit report block per `exit-report-format.md` with command output | "Fixed the findings" |
| PR merge-ready | `merge-gate.sh` exit 0 **and** zero unresolved threads **and** CI clean on HEAD | Local review only |
| Skill conventions OK | `bash .claude/scripts/skill-conventions-audit.sh` exit 0 when the script is present on the branch (issue #417); else `rule-lint.sh` + frontmatter spot-check | Eyeballing frontmatter |

## When the diff cannot prove a requirement

Name the requirement, why the diff cannot establish it, and the smallest
next check on the exact proposed commit. Put that note in the existing
review or handoff so the person verifying acceptance can act on it. A
clean review is still useful for what it covered. It does not supply the
missing evidence, and the acceptance item stays unchecked if the check
cannot run or is inconclusive.

For example, a PR changes a helper used by an unchanged installed caller.
Report: **Requirement:** the caller still resolves and invokes the helper
outside the config checkout. **Evidence needed:** at the proposed commit,
run the existing portability fixture or invoke the unchanged caller with
the installed helper layout from a checkout without `.claude/`. **If it
cannot run:** report that the installed caller is unverified; leave its
acceptance item unchecked.

Adapted from [Superpowers' diff review guidance](https://github.com/obra/superpowers/blob/22f0b463e7a5e579904dd6211a520321035526f7/skills/subagent-driven-development/references/cannot-verify.md).
The existing acceptance and merge gates still apply.

## Red flags — stop and verify

- "Should pass now", "probably clean", "looks good"
- Satisfaction words before running proof ("Done!", "All set!", "Merge-ready!")
- Trusting subagent "success" without VCS diff or test output
- Partial checks (linter only when tests are the claim)
- Quoting CI/CR from a SHA that is not current HEAD after your last push
- Ticking Test plan checkboxes before running the listed verification

## Rationalization table

| Excuse | Reality |
|--------|---------|
| "CR was clean earlier" | Re-run on current diff |
| "Subagent said tests pass" | Run the test command yourself |
| "Linter is clean" | Linter ≠ tests ≠ merge gate |
| "Just this once" | No exceptions — exit reports are audit trail |
| "Different wording so rule doesn't apply" | Spirit over letter |
| "User wants it merged" | Gate first, merge second |

## Where this applies in our skills

- **Merge-gate Step 2 AC verification** (`ac-checkboxes.sh` call sites) — each AC item needs mapped evidence before `--tick` or `--all-pass`
- **`/wrap`, `/merge`, `/go-on`** — `merge-gate.sh` + thread/CI proof on HEAD
- **`/fixpr`** — zero failing checks means `ci-status` output, not assumption
- **Phase A/B/C exit reports** — include command output snippets per `exit-report-format.md`
- **CONTRIBUTING PRs** — Test plan checkboxes are claims; verify before checking

## Related

- `.claude/reference/exit-report-format.md` — structured proof blocks
- `.claude/rules/cr-local-review.md` — local CR loop
- `.claude/rules/cr-merge-gate.md` — GitHub merge gate
- superpowers plugin `verification-before-completion` — generic discipline skill
