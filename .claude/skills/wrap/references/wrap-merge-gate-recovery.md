# `/wrap` Step 2.1 — Merge-Gate Recovery Loop: Branch Detail

Referenced from `wrap/SKILL.md` Step 2.1. Contains the per-branch mechanics and pitfall notes; the SKILL.md keeps only the dispatch skeleton.

## Terminal checks (every iteration)

```bash
STATE=$(gh pr view "$PR_NUM" --json state --jq '.state')
```

Use `state` — **not** a `merged` field. `gh` has no `merged` JSON field; `--json merged` fails with `Unknown JSON field: "merged"` (issue #608).

- `MERGED` → exit loop for Phase 3 (post-merge phases run normally).
- `CLOSED` → stop with status; do not merge.

## Gate refresh (every iteration)

```bash
GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
GATE_EXIT=$?
HEAD_NOW=$(printf '%s' "$GATE_JSON" | jq -r '.head_sha // empty')
```

**Use `printf '%s'`, never `echo`** — zsh's builtin `echo` interprets escape sequences and corrupts the JSON payload, yielding a parse error or an empty `HEAD_NOW` that defeats the no-stale-SHA contract (issue #574).

Exit codes: `3` = PR not found/not open (Phase 3 handling); `2`/`4` = tooling failure (surface stderr, stop); `0` = gate met (proceed to Step 2.2 unless findings still outstanding, see SKILL.md).

## Human CHANGES_REQUESTED (exit 1 — genuine block)

When `human_changes_requested` is a **non-empty array**: stop immediately. Message must **name each login** from the array. Do **not** run `dismiss-stale-bot-changes.sh`. Do **not** squash-merge.

## Branch A — Stale bot CHANGES_REQUESTED

When `(.stale_bot_changes_requested_count // 0) > 0`, invoke dismissal without waiting for a push (same allowlist + semantics as `/fixpr` Step 3a):

```bash
[[ -n "$DISMISS" ]] && "$DISMISS" "$PR_NUM"
```

`DISMISS` is resolved via `resolve_script()` before the loop (see SKILL.md preamble). Record dismiss exit code in audit. **Never** use this branch when `human_changes_requested` is non-empty.

Then: if `mergeable == CONFLICTING` — stop immediately; recommend **`/merge-conflict`** or manual resolution. Do not proceed to Branch B.

## Branch B — Delegate `/fixpr`

Run when **any** of: `missing` mentions unresolved review threads; `merge_state == "BEHIND"`; `missing` reports CI failing (not merely incomplete); `merge_state == "DIRTY"`; or Phase 1 left `WRAP_PHASE1_FINDINGS` pending.

**Threads-only detection (issue #455 / #479):** classify using `merge-gate.sh`'s structured signals:

```bash
THREADS_ONLY=$(printf '%s' "$GATE_JSON" | jq -r '
  ((.unresolved_thread_count // 0) > 0)
  and (((.missing // []) | length) == 1)')
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
if [ "$THREADS_ONLY" = "true" ]; then
  echo "[$TS] Phase 2.1: merge gate blocked by unresolved review threads only — invoking /fixpr (issue #455)"
else
  echo "[$TS] Phase 2.1: gate blocked (mixed/other blockers) — invoking /fixpr per #452 decision tree"
fi
```

**Execution contract:** Execute the **full** `.claude/skills/fixpr/SKILL.md` workflow (Steps 0–7, including Step 4d review-wait loop). Do NOT shell out to an opaque wrapper. If spawning a Phase A subagent: use `mode: "bypassPermissions"`, explicit `model`, SAFETY block, handoff path per `subagent-orchestration.md` — parent stays in monitor mode.

Parse the `=== fixpr complete ===` footer for `Status:`, `FIXPR_WRAP_STATUS`, and `FIXPR_WAIT_SUMMARY`. On return, emit a control-returned heartbeat:

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
echo "[$TS] Phase 2.1: /fixpr returned — Status: $FIXPR_WRAP_STATUS ($FIXPR_WAIT_SUMMARY)"
```

Full handoff semantics and verdict-trust contract: `.claude/reference/wrap-fixpr-delegation.md`.

**Stop conditions after `/fixpr`:**

- `CI_FAILING` with deterministic failures you cannot fix in-session → stop; surface `missing` / CI summary + audit.
- `THREADS_STUCK`, `NEEDS_HUMAN_REVIEW`, or `NEW_FINDINGS` where unresolved → stop with audit; list each `[STUCK] <url> — <reason>` line from `/fixpr`'s footer.
- `REVIEW_PENDING` (`final=cap-exhausted` — bots still pending) → re-enter loop; next gate re-check routes to Branch C or D. Outer cap still applies.
- `CI_PENDING` (`final=cap-exhausted` with CI incomplete) → re-enter loop; next gate routes to Branch D. Outer cap still applies.
- `BEHIND` → `/fixpr` rebased/force-pushed; re-run gate. If `/fixpr` reported a clean `BEHIND` auto-merged via `admin-merge.sh --auto-plain` (issue #754), the PR is already merged — skip loop, relay the `AUTO_PLAIN_MERGED` evidence block, go to post-merge phases.
- `CONFLICTS` → stop; recommend `/merge-conflict` or manual resolution.
- `CLEAN` → continue to next recovery iteration (re-run gate).

When CR hourly budget blocks an internal `@coderabbitai full review` inside `/fixpr`, `/fixpr` surfaces it — `/wrap` records it and **stops** (no infinite loop).

## Branch C — Missing fresh bot review signal

When `missing` indicates stale/dismissed bot approval or missing CR/BugBot/CodeAnt/Greptile signal per `cr-merge-gate.md`, trigger the **one** bot your repo needs:

- **CodeRabbit:** run `.claude/scripts/cr-review-hourly.sh --check` first. Exit `1` → **stop** with JSON snapshot and `cr-github-review.md` rate-limit guidance — do not loop until cap resets.
- **Greptile:** `@greptileai` only when Greptile is the owning path / code owner (per `greptile.md`).
- **CodeAnt:** `@codeant-ai review` when CodeAnt owns the gap.
- **BugBot:** post `@cursor review` when `reviewer == "bugbot"` per `reviewer-of.sh` or `session-state.json` — duplicates OK, except on a HEAD BugBot already refused for spend, where no nudge can help (`bugbot.md`).

Then **delegate the wait to `/fixpr`** (issue #454 — no wrap-side sleeps): run the `/fixpr` workflow; its idempotent path makes no push when nothing needs fixing, and its Step 4d loop waits on the current SHA until the triggered bot completes or the 20-min cap fires. Parse `FIXPR_WAIT_SUMMARY`, append to audit, re-run `merge-gate.sh` immediately.

## Branch D — CI incomplete only

Do not fix anything. Delegate the wait to `/fixpr` (idempotent — no push; its Step 4d loop polls until non-review-bot CI completes or the cap fires). Append "waited for CI via /fixpr: `<FIXPR_WAIT_SUMMARY>`" to audit, re-run the gate, continue to next iteration if under cap.

## Branch E — Branch-protection block

When the **only** outstanding blocker is `missing` reporting `branch protection reviewDecision is … not APPROVED, with <bot> in CODEOWNERS` **and** that bot already has a fresh `APPROVED` on HEAD (so Branch C's re-trigger won't help — the AI reviewer auto-skipped the code-owner path), this is the solo-owner `enforce_admins` bypass scenario.

**Stop and suggest `/admin-merge <PR>`** — never tell the user to toggle `enforce_admins` in the GitHub UI, and never modify branch protection yourself. `/admin-merge` prints a user-runnable bypass command (gate is re-verified first). Record the suggestion in the audit.

**A clean `BEHIND` is NOT this branch (issue #754):** that bypass changes no protection — `/fixpr`'s BEHIND row auto-runs `admin-merge.sh <PR> --auto-plain --ac-verified` and the merge completes without a user turn. Only a protection-**modifying** bypass stops here.

## `merge_state == UNKNOWN`

GitHub is still computing mergeability. Re-run `merge-gate.sh` on the next iteration (the gate call provides the spacing — no sleep). If still unknown at cap, stop with audit.

## Unclassified blocker

If no branch matched and gate still fails: append "unclassified blocker" + full `missing` to audit and advance to next `i`.

## Safety invariants (non-negotiable)

- **Never** call GitHub APIs that modify **branch protection** (`.../branches/.../protection`). Suggest `/admin-merge` (Branch E) for the solo-owner scenario — it prints a command for the **user** to run. Unaffected by this: `admin-merge.sh --auto-plain`, which issues no protection call.
- **Never** dismiss **human** reviews — only `dismiss-stale-bot-changes.sh` (bot allowlist, wrong `commit_id`).
- **Never** resolve a review thread **without** verifying the code addresses the comment (`/fixpr` Steps 1–4 verify-address → reply → resolve).
