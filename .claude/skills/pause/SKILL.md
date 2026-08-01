---
name: pause
description: Use when you can see your usage allowance running thin and want to stop cleanly rather than be cut off mid-flight, or when you want to carry this session's work into another tool (Cursor, a fresh thread, a colleague). Winds down without killing running work, then writes a self-contained handoff document that a reader outside this harness can act on. Triggers on "pause", "clean pause", "wind down", "portable handoff", "hand this to Cursor", "I'm running low".
triggers:
  - pause
  - clean pause
  - wind down
  - portable handoff
  - hand off to Cursor
argument-hint: "(no arguments)"
---

Stop cleanly on demand, and leave behind a document someone else can pick up.

**You decide when.** The usage view in the app is the authoritative source for what is left of your allowance, and you are the one reading it. This command never estimates tokens, spend, or remaining quota, and never refuses or defers work based on one — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" holds as written. `/pause` runs because you asked, and for no other reason.

Two outputs, in this order: a wind-down that leaves nothing half-finished, and a portable handoff document written to disk and printed in the thread.

## Step 0: Resolve the helper scripts

`/pause` is invocable from any thread — including one whose working directory is not this repo, which is exactly the situation where a repo-relative path silently fails. Resolve each helper the same way the other stop-style commands do:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || SESSION_STATE_SH=""
HANDOFF_LINT_SH=$(resolve_script portable-handoff-lint.sh) || HANDOFF_LINT_SH=""

# The collector is a document, not a script, so resolve it the same way but
# test for readability rather than the executable bit.
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/reference/session-state-collector.md" \
  "$HOME/.claude/reference/session-state-collector.md" \
  ".claude/reference/session-state-collector.md"; do
  [[ -r "$candidate" ]] && { COLLECTOR_DOC="$candidate"; break; }
done
COLLECTOR_DOC="${COLLECTOR_DOC:-}"
```

Neither is fatal. An unresolved `session-state.sh` means the wind-down cannot be persisted — say so in Step 2's report and carry on, because the document is the part that matters. An unresolved checker is handled by Step 5's "could not run" branch.

## Step 1: Wind down — stop starting, do not stop finishing

Stop launching new work. Do **not** kill what is already running: a subagent interrupted mid-push leaves a branch in a state nobody has recorded, which is the exact outcome this command exists to prevent. Let running units reach their own stopping point and write their own handoffs.

Persist the stop so it survives context turnover and is visible to every other skill that launches work:

```bash
WINDDOWN_PERSISTED=1     # assume success, then prove otherwise below
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key)
  NOW=$(date -u +%FT%TZ)
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].refill={\"paused\":true,\"reason\":\"full_stop\",\"scope\":null,\"at\":\"$NOW\"}" \
    || WINDDOWN_PERSISTED=0
else
  WINDDOWN_PERSISTED=0   # Step 0 could not resolve the helper
fi
```

The initialiser is not decoration: without it the variable is simply unset on the success path, and Step 2 — which tests for `1` — would report every successful pause as unrecorded.

**When `WINDDOWN_PERSISTED` is 0, the stop was not written down.** Say that in Step 2's report in plain words — "I could not record the pause, so another thread may still start new work" — rather than printing a `Stopped:` line that claims something untrue. Then carry on to the document, which is the part that survives this session either way.

This is the **existing** launch gate that `/pm` Step 3.4 and `/subagent` Step 7 already read before every launch — no new field, no new mechanism. `reason` stays inside its bounded enum (`full_stop` | `scope_narrowed`); `/pause` is a human saying stop in chat, which is exactly what `full_stop` means, so it does not get a value of its own.

**It stays paused until a human resumes it.** Not on the next tick, not on an unrelated later message, not on a fresh scan. Say so in the report (Step 2) — a pause the user cannot see is one they cannot lift.

Then read what is currently running, so the report can name it:

```bash
[[ -n "$SESSION_STATE_SH" ]] && "$SESSION_STATE_SH" --session-view
```

`active_agents` records what was launched, not what is still alive. Treat it as a list to verify, not a fact. With no helper resolved there is no list — report "could not read what was running" rather than "nothing was running", which are different claims.

## Step 2: Report what stopped and what was left running

Print this immediately — before collection, which takes a moment. The user asked to stop; they should see that stopping has begun.

```text
=== Winding down ===
Stopped:   <WINDDOWN_PERSISTED=1: "new work will not be started (refilling paused until you say resume)">
           <WINDDOWN_PERSISTED=0: "COULD NOT record the pause — another thread may still start new work. Say stop in chat to pause it.">
Finishing: <one line per running subagent or pipeline — what it is and which PR/issue it belongs to, or "nothing was running">
Untouched: <anything deliberately left alone — open PRs still awaiting review, armed watchers — or "nothing">
```

The `Stopped:` line has two forms and the choice is not stylistic. Printing the first after a failed write tells the user something untrue about the one side effect this command has, and they would find out only when a pipeline started anyway. Pick the form that matches `WINDDOWN_PERSISTED`.

Likewise, when `$SESSION_STATE_SH` was never resolved there is no running-work list to read — `Finishing:` says "could not read what was running", never "nothing was running".

Nothing in this block is a question. If a running unit looks stuck, say so on its line; do not stop it and do not ask whether to.

## Step 3: Collect the state

Follow the collector resolved as `$COLLECTOR_DOC` in Step 0 — the same one `/pm-handoff` uses. Collect all five categories, including §5 (uncommitted and unpushed local state), which only this command needs.

**Read it by its resolved path, not by a repo-relative one.** From another checkout `.claude/reference/session-state-collector.md` simply does not exist, and an unreadable collector produces the same silence as an empty session. If `$COLLECTOR_DOC` is empty, say in Step 2's report that collection ran without it and gather what you can directly — an unguided pass is worth more than a document that reports nothing in flight because it could not look.

**Substitute the paths resolved in Step 0 for the collector's `.claude/scripts/…` literals.** Those literals resolve only from this repo, and a `/pause` run from anywhere else would get command-not-found on every read — which looks exactly like a session with nothing in flight. Reporting "no in-flight work" when the truth is "could not look" is the one mistake this document cannot afford, because the reader has no way to detect it.

Every category can be legitimately empty. An empty category is reported as empty; it never aborts collection and never produces an error. **A category that could not be *read* is not empty** — say so in those words.

## Step 4: Render the portable document

Build the document from `references/portable-handoff-template.md`, following its rendering rules. Render **once**, into a single buffer — that one buffer is what gets verified, written, and printed.

The reader is an agent or person with the repository and this document and nothing else: no rules loaded, no state files, no knowledge of our conventions, possibly not Claude at all. Translate every internal concept into what someone can act on (the template has the translation table).

## Step 5: Verify portability — this is a gate, not a review

Write the buffer to a temporary file **in the destination directory** and check it:

```bash
OUT_DIR="$HOME/.claude/handoffs"
mkdir -p "$OUT_DIR"
TMP_DOC=$(mktemp "$OUT_DIR/.portable-handoff.XXXXXX")
# ... write the rendered buffer to "$TMP_DOC" ...
if [[ -n "$HANDOFF_LINT_SH" ]]; then
  # Bind the skill catalog to the checker's OWN repo, not the cwd. Without
  # --repo-root, a /pause run inside some other project that also happens to
  # have a .claude/skills directory would validate against THAT project's
  # command list — and a document full of this harness's commands would pass.
  LINT_ROOT=$(cd "$(dirname "$HANDOFF_LINT_SH")/../.." 2>/dev/null && pwd)
  if [[ -n "$LINT_ROOT" ]]; then
    "$HANDOFF_LINT_SH" --repo-root "$LINT_ROOT" "$TMP_DOC"; LINT_RC=$?
  else
    "$HANDOFF_LINT_SH" "$TMP_DOC"; LINT_RC=$?
  fi
else
  LINT_RC=2   # checker not found in Step 0 — same branch as "could not run"
fi
```

Staging inside `$OUT_DIR` — not `$TMPDIR` — keeps Step 6's `mv` on one filesystem, where it is a real atomic rename rather than a copy a reader can catch half-finished.

- **`LINT_RC` 0** — proceed to Step 6.
- **`LINT_RC` 1** — the document names something the reader cannot use. Rewrite each reported line in plain English, then re-run. Do not emit a failing document, and do not edit the checker to make a line pass.
- **Anything else** (2, 3, an unresolved checker, or a non-zero the checker does not define) — the check could not run. Emit the document anyway, and say plainly in the thread that it went out **unverified**, naming what stopped it. An unverified handoff is worth more than no handoff; an unverified handoff the user believes was checked is worth less than nothing.

The lint also enforces that every required section exists and has content, which is what keeps graceful degradation from quietly producing an empty shell.

## Step 6: Emit — write, then print the same bytes

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUT_DIR/portable-handoff-${STAMP}-${SESSION_ID}.md"
mv -f "$TMP_DOC" "$OUT" && chmod 644 "$OUT"
echo "$OUT"
```

Same-directory `mktemp` + `mv` is an atomic single-writer publish — a reader sees a complete document or none. Naming and format: `.claude/reference/portable-handoff.md`.

If the `mv` fails, say so and print the temp file's path — never report a write that did not happen.

Then print the **same buffer** in the thread, in one fenced block, so it can be copied without a file read. Do not re-render for display: a second render is a second document, and the reader has no way to tell which one they got.

Close with the file path on its own line, so the next session (and the usage-limit recorder, which points at the most recent one of these) can find it.

## Relationship to the other end-of-something commands

| Command | Ends | Produces |
|---|---|---|
| `/wrap` | a pull request | a merge, follow-up issues, lessons |
| `/pm-handoff` | a thread | a prompt for the next thread in this harness |
| `/pause` | a working session | a document for a reader **outside** this harness |

They overlap in what they read — hence the shared collector — and not at all in what they produce. `/pause` does not merge anything, does not close anything, and does not decide that work is finished. It records where the work actually is and stops.

## Not this command's job

- **Estimating anything.** No token count, no spend figure, no "you have about N left". You read the usage view; this command does not model it.
- **Deciding when to stop.** It runs when invoked. It does not fire on a schedule, a threshold, or an inference.
- **Killing running work.** Step 1 stops launches only.

When a real approaching-limit signal eventually reaches a hook, the wind-down built on it emits **this** document rather than defining its own (issue #835) — the trigger changes, the artifact does not.
