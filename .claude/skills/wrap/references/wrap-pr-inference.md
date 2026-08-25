# `/wrap` Step 1.1 — PR Inference Cascade (Full Detail)

Referenced from `wrap/SKILL.md` Step 1.1. Contains the full sub-step logic the SKILL.md summarizes as a pointer.

## Overview

The cascade resolves the target PR in order — first match wins, later sub-steps skipped:

- **1.1a** Explicit argument (`$ARGUMENTS` non-empty) — resolve and skip all else.
- **1.1b** Current branch — `gh pr view` finds a PR; use it (non-inferred path).
- **1.1c** Thread context scan — most recent `/fixpr`/`/wrap` invocations, explicit PR refs (AI judgment).
- **1.1d** Session-state — `infer-pr.sh --root-repo` candidates scoped to this repo.
- **1.1e** Merge, deduplicate, resolve — single / unambiguous / ambiguous / no-candidates.
- **1.1f** No-candidates stop message — non-coding thread vs. lookup-failed (AI judgment).

Emit `[INFERRED]` line before any Phase 1 verification when `INFERRED_SOURCE` is set (i.e. NOT the plain 1.1b branch path). Pause briefly for the user to interrupt.

## 1.1a — Explicit argument

```bash
OWNER_REPO=""   # repo the resolved PR lives in, when known
if [[ -n "${ARGUMENTS:-}" ]]; then
  if [[ -z "$INFER_PR" ]]; then
    echo "STOP: /wrap was given '$ARGUMENTS' but infer-pr.sh was not found (checked all three paths) — cannot safely resolve an explicit PR reference. Install the shared helper, or run /wrap with no argument from the PR's branch." >&2
    # STOP — do NOT fall through to 1.1b (would risk wrapping the wrong PR).
  elif EXPLICIT_JSON=$("$INFER_PR" --explicit "$ARGUMENTS"); then
    PR_NUM=$(jq -r '.most_recent.number' <<<"$EXPLICIT_JSON")
    OWNER_REPO=$(jq -r '.most_recent.owner_repo // empty' <<<"$EXPLICIT_JSON")
    INFERRED_SOURCE="explicit argument"
  else
    echo "STOP: could not parse '$ARGUMENTS' as a PR reference (URL, owner/repo#N, #N, or N)." >&2
    # STOP — do NOT fall through for a malformed explicit arg.
  fi
fi
```

A non-empty `$ARGUMENTS` must **never** fall through to 1.1b — that could wrap a different PR.

## 1.1b — Current branch

```bash
BRANCH_PR=$(gh pr view --json number,title,headRefName,body,state \
  --jq '{number, title, headRefName, body, state}' 2>/dev/null || true)
```

If found: use it (`PR_NUM` = its number, `INFERRED_SOURCE` unset — normal non-inferred path). Skip 1.1c–1.1e.

## 1.1c — Thread context scan (AI judgment)

If 1.1a and 1.1b found nothing, scan the **current conversation** (most recent first):

- Most recent `/fixpr <URL>` or `/wrap <URL>` invocation in this thread.
- Explicit PR references the thread acted on — `PR #N`, `github.com/<owner>/<repo>/pull/N`, or a `=== fixpr complete === PR: #N` footer.

Rank by position (more recent = stronger). If the chosen reference was a full URL, capture its `<owner>/<repo>` into `OWNER_REPO` for the repo-scoping guard.

## 1.1d — Query session-state

Capture the real exit code — do NOT append `|| true` (masks exit 1/2/4):

```bash
ROOT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if SESSION_JSON=$("$INFER_PR" --root-repo "$ROOT_TOPLEVEL"); then
  SESSION_RC=0
else
  SESSION_RC=$?
fi   # 0 single, 1 multiple, 2 none, 3/4 error
```

## 1.1e — Merge, deduplicate, resolve

Combine thread-context candidates (1.1c) + session-state candidates (1.1d), deduplicate by PR number, rank by recency (thread-context order over session-state `last_activity`). Resolution rules:

- **Single candidate**: proceed.
- **Most-recent-unambiguous** (one clearly more recent, e.g. active within last ~5 min): proceed on it, surface rest with `Also tracking:` line.
- **Ambiguous** (tied in recency): **stop** — list candidates with source/last-activity, ask user to specify: `Multiple PRs in scope — please specify: /wrap <N>`.
- **No candidates** (`SESSION_RC == 2`, 1.1b empty, 1.1c found nothing): stop per **1.1f**.

## 1.1f — No-candidates stop message (AI judgment)

Scan the **current conversation** for signals that this thread never contained coding work:

- The thread ran `/issue-maker`, or declared itself capture-only / issue-only mode.
- The thread's entire output was creating/editing/commenting on issues — no implementation.
- The thread is PM/monitoring/orchestration only (`/pm`, `/status`, `/standup`, `/recap`) with no code written.
- The thread explicitly concluded the work was already solved elsewhere, or nothing to implement.
- No branch, worktree, commit, push, or PR was ever created or discussed.

**Tiebreak (mandatory):** Emit the no-coding message **only** when the thread affirmatively shows those signals. If absent, weak, mixed, or uncertain — emit the lookup-failed message. A redundant `/wrap <N>` hint costs nothing; telling someone "nothing to wrap" while they sit on a real PR is the worse failure.

```
# Non-coding thread detected:
This thread has no coding work in it, so there's nothing to wrap. No action needed.

# No detection signal (default):
No PR found for the current branch. If you meant a specific PR, name it: /wrap <N>
```

## Repo-scoping guard

After `PR_NUM` is resolved, if `OWNER_REPO` is known (set from 1.1a URL/`owner/repo#N` or 1.1c thread URL) and differs from the current repo — **stop**:

```bash
CURRENT_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [[ -n "${OWNER_REPO:-}" && -n "$CURRENT_REPO" && "$OWNER_REPO" != "$CURRENT_REPO" ]]; then
  echo "STOP: the target resolves to $OWNER_REPO#$PR_NUM, but this checkout is $CURRENT_REPO. /wrap's merge, AC, and main-sync steps are scoped to the current checkout — re-run /wrap from a $OWNER_REPO checkout (or its worktree)." >&2
fi
```

References without an `owner_repo` (`#N`, bare `N`, 1.1b branch PR, or session-state candidates already scoped to this repo) are assumed in the current checkout — guard is a no-op.

## Authorship guard

Once `$PR_NUM` is resolved and the repo-scoping guard passes:

```bash
"$PR_AUTHORSHIP_SH" "$PR_NUM"   # exit 0 = yours
```

Not yours (exit 1) or undetermined (exit 4) → **stop** with: "PR #$PR_NUM is authored by someone else — the authorship guard blocks automated merges; name this PR explicitly to override." Proceed only under an explicit per-PR user override (pass `--allow-nonauthor` to `merge-gate.sh` in Step 2). `merge-gate.sh` also blocks a confirmed foreign author as a fail-safe.
