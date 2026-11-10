# Cost-first worker routing and patient retries

Issue #1875. This contract governs unattended phase A/B/C, PM and read-only
worker launches. It does not change the running parent model, the owner's
interactive picker, permissions, tool allowlists, review independence or gates.

## Before each launch

Resolve `model-route.sh` through the usual shared-tool paths. Run it with
`--input <request.json>`. It makes no provider calls and changes no state.
Supply an explicit current runtime inventory, not guessed availability. The
configured unattended ladder is Haiku → Sonnet → Opus; Fable requires an explicit
owner choice. This is an ordinal cost policy, not a dollar estimate or a claim
that every task succeeds on Haiku. Actual availability and capability win over
the ladder. Source: [provider pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[subagent model/tool configuration](https://code.claude.com/docs/en/sub-agents).

For each candidate confirm tool support, required context, the agent's unchanged
permission/tool restrictions, provider availability and budget/reserve controls.
`capable` means these requirements are supported, not that a first patch is
guaranteed correct. Unknown capability/availability is ineligible. A provider
limit is handled by existing park/wake controls, never an excuse to buy another
tier or silently switch accounts. Preserve the existing reserve gate's own
freshness/unknown semantics; the routing helper does not reinterpret its marker.

Request shape (the inventory below is illustrative, not a live authorization):

```json
{
  "task": "issue-123", "phase": "A",
  "launch_allowed": true, "permissions_preserved": true,
  "runtime": {"version": "2.1.312", "model_override_forced": false},
  "owner_model": null, "current_model": null,
  "models": [{
    "model": "haiku", "available": true, "capable": true,
    "budget_allowed": true, "reserve_allowed": true,
    "evidence": "path/to/current-runtime-and-launch-check.json"
  }],
  "attempts": [],
  "submission": {
    "local_checks_passed": false, "distinct_changes": false, "batched": false
  }
}
```

`launch_allowed` is true only after the existing refill, pause, deadline,
capacity, claim and provider/budget gates permit this launch. Never set a flag
merely to make routing pass. Refresh inventory and these controls at each
successor; do not reuse a stale clear result. `owner_model` is only an explicit
owner selection for this task, not an old phase default or a generated model
recommendation. If pinned and unavailable, block; never silently substitute.

The result contains `action`, `model`, `reason`, evidence IDs and metrics. Exit
0 permits `start`, `retry`, `escalate`, or reports `complete`; only the first
three launch. Exit 3 (`wait`, `diagnose`, `owner_decision`, `blocked`) launches nothing;
persist the pending work and recover or surface an owner-only decision as
appropriate. Exit 2 means invalid/unreadable input: retain the error and repair
the request, never fall back to a premium literal.

### Runtime precedence preflight

Require a verified runtime version at least 2.1.251 and an explicitly false
`runtime.model_override_forced`. The caller reads the active Claude runtime
version and effective `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, not merely a source
settings file. Missing/older versions or forced/unknown overrides block routing.
The [official 2.1.251 release](https://github.com/anthropics/claude-code/releases/tag/v2.1.251)
changed the legacy model environment setting to a default; earlier clients can
ignore a routed alias in favor of the installed premium pin. Current
[provider docs](https://code.claude.com/docs/en/sub-agents) separately describe
forced overrides. Do not silently edit owner settings or clear an explicit pin.
This repository's old seeded fallback therefore requires a compatible client;
verify the effective model with runtime telemetry after launch as well. The
version shown in the JSON example is illustrative, not automatic detection.

## State and dispatch integration

Before first dispatch, store the request and result in the existing repo-scoped
session record (`.repos["owner/repo"].tasks["issue-N"].model_routing["A"]` for issue work; another
explicit task key for read-only PM work). Once a PR exists, use its selected handoff's
`.model_routing["task-id"]["A"|"B"|"C"]`. Use `session-state.sh`/`handoff-state.sh` with
explicit repository scope and their locks. Copy the current phase's routing
record when creating its handoff; preserve earlier attempts rather than
rebuilding from chat or resetting retry counts. Do not add another state store.

The parent constructs the bounded request from those records and raw evidence
pointers, writes it to a scratch JSON file, then runs the helper. Parse its JSON
only after capturing its exit code. Persist `{request, decision}` using the
owning locked helper **before** dispatch. A failed state write stops dispatch.
Set the Agent call's explicit `model` to the returned alias, keeping its existing
agent type, permissions, tools, worktree, claim and silence ceiling. Agent
frontmatter is a cheap fallback, never a substitute for this preflight.

Run this block before **every** Agent call with `MODEL_ROUTE_REQUEST` naming
that phase's request JSON, `OWNER_REPO` verified, and the three helpers resolved
through the shared-tool candidate order. Set `PR_NUMBER` only after that PR's
handoff exists; otherwise task state is owned by the repo session record. The
resulting `ROUTED_MODEL` is the Agent call's alias, not a literal default.

<!-- test-anchor: task-model-route-dispatch -->
```bash
# task-model-route-dispatch
: "${MODEL_ROUTE_REQUEST:?routing request required}" "${OWNER_REPO:?verified repo required}"
: "${MODEL_ROUTE_SH:?resolver required}" "${SESSION_STATE_SH:?state helper required}"
MODEL_ROUTE_RC=0
MODEL_ROUTE_DECISION=$("$MODEL_ROUTE_SH" --input "$MODEL_ROUTE_REQUEST") || MODEL_ROUTE_RC=$?
MODEL_ROUTE_RECORD=$(jq -cn --slurpfile request "$MODEL_ROUTE_REQUEST" \
  --argjson decision "$MODEL_ROUTE_DECISION" '{request:$request[0], decision:$decision}') || exit 2
MODEL_ROUTE_TASK=$(jq -er ' .request.task | strings | select(length > 0)' <<<"$MODEL_ROUTE_RECORD") || exit 2
MODEL_ROUTE_PHASE=$(jq -er '.request.phase | strings | select(length > 0)' <<<"$MODEL_ROUTE_RECORD") || exit 2
if [ -n "${PR_NUMBER:-}" ]; then
  : "${HANDOFF_STATE_SH:?handoff helper required}"
  MODEL_ROUTE_FILTER=$(jq -nr --arg task "$MODEL_ROUTE_TASK" --arg phase "$MODEL_ROUTE_PHASE" --argjson record "$MODEL_ROUTE_RECORD" \
    '".model_routing[" + ($task|tojson) + "][" + ($phase|tojson) + "]=" + ($record|tojson)') || exit 2
  "$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --require-existing \
    --set "$PR_NUMBER" "$MODEL_ROUTE_FILTER" || exit 4
else
  [[ "$OWNER_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
  MODEL_ROUTE_REPO=$(printf '%s' "$OWNER_REPO" | tr '[:upper:]' '[:lower:]')
  MODEL_ROUTE_TASK=$(jq -er '.request.task | strings | select(length > 0)' <<<"$MODEL_ROUTE_RECORD") || exit 2
  MODEL_ROUTE_FILTER=$(jq -nr --arg repo "$MODEL_ROUTE_REPO" --arg task "$MODEL_ROUTE_TASK" --arg phase "$MODEL_ROUTE_PHASE" \
    --argjson record "$MODEL_ROUTE_RECORD" \
    '".repos[" + ($repo|tojson) + "].tasks[" + ($task|tojson) + "].model_routing[" + ($phase|tojson) + "]=" + ($record|tojson)') || exit 2
  "$SESSION_STATE_SH" --repo "$OWNER_REPO" --set "$MODEL_ROUTE_FILTER" || exit 4
fi
[ "$MODEL_ROUTE_RC" -eq 0 ] || exit "$MODEL_ROUTE_RC"
MODEL_ROUTE_ACTION=$(jq -er '.action' <<<"$MODEL_ROUTE_DECISION") || exit 2
case "$MODEL_ROUTE_ACTION" in start|retry|escalate) ;; *) exit 3 ;; esac
ROUTED_MODEL=$(jq -er '.model | strings | select(length > 0)' <<<"$MODEL_ROUTE_DECISION") || exit 2
```

### Creating or updating a Phase A handoff

Pass the stable task identity and current request/record file pointers in every
child prompt. The child loads `MODEL_ROUTE_RECORD` into a shell variable from
the current record file (without printing whole histories into model context),
and creates/updates `MODEL_ROUTE_REQUEST` from its `.request` as needed.
The initial PR handoff must copy that current phase record from session state;
subsequent fix tasks retain earlier task histories. Use this write block with
the existing `HANDOFF_JSON` metadata instead of an overwriting `--create`.
Each literal assignment uses the handoff helper's lock; write the completion marker last. Never read/overwrite the whole existing record outside that lock.

<!-- test-anchor: routed-handoff-write -->
```bash
# routed-handoff-write
: "${MODEL_ROUTE_RECORD:?current routing record required}" "${OWNER_REPO:?repo required}" "${PR_NUMBER:?PR required}"
jq -e '.request.task == .decision.task and .request.phase == .decision.phase' <<<"$MODEL_ROUTE_RECORD" >/dev/null || exit 5
jq -e 'type == "object" and (.phase_completed|type == "string") and (keys | all(test("^[A-Za-z_][A-Za-z0-9_]*$")))' <<<"$HANDOFF_JSON" >/dev/null || exit 5
ROUTED_HANDOFF_ASSIGNMENT=$(jq -nr --argjson route "$MODEL_ROUTE_RECORD" \
  '".model_routing[" + ($route.request.task|tojson) + "][" + ($route.request.phase|tojson) + "]=" + ($route|tojson)') || exit 5
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --init "$PR_NUMBER" '{}' || exit 5
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --require-existing --set "$PR_NUMBER" "$ROUTED_HANDOFF_ASSIGNMENT" || exit 5
ROUTED_METADATA_ROWS=$(jq -c 'to_entries[] | select(.key != "model_routing" and .key != "phase_completed")' <<<"$HANDOFF_JSON") || exit 5
while IFS= read -r ROUTED_METADATA_ROW; do
  [ -n "$ROUTED_METADATA_ROW" ] || continue
  ROUTED_METADATA_ASSIGNMENT=$(jq -r '".[" + (.key|tojson) + "]=" + (.value|tojson)' <<<"$ROUTED_METADATA_ROW") || exit 5
  "$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --require-existing --set "$PR_NUMBER" "$ROUTED_METADATA_ASSIGNMENT" || exit 5
done <<<"$ROUTED_METADATA_ROWS"
ROUTED_COMPLETION=$(jq -c '.phase_completed' <<<"$HANDOFF_JSON") || exit 5
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --require-existing --set "$PR_NUMBER" ".phase_completed=$ROUTED_COMPLETION" || exit 5
```

On retry, pass only the task/AC, current phase, source pointers, approaches,
discoveries, remaining blocker, verification and next action. Load the relevant
phase module, not a giant skill/transcript. Resume the same model if context
permits; a fresh context uses that same model and compact handoff. A model step
is a **new task/phase context**, never a mid-session switch. Other tasks and
phases retain their own cheapest eligible routes.

## Attempt evidence and diagnosis

Append each finished attempt to the phase record before routing again:

```json
{
  "id": "attempt-1", "model": "haiku", "outcome": "failed",
  "bug": "parser-precedence", "signature": "weekly-classified-as-credit",
  "approach": "check-weekly-before-credit",
  "method_fingerprint": "1111111111111111111111111111111111111111111111111111111111111111",
  "method_evidence": "path/to/normalized-operation-or-patch.json",
  "evidence": ["path/to/local-check.json"], "new_evidence": [],
  "remaining_blocker": "mixed-message precedence still fails",
  "poor_patch": false, "review_rounds": 0, "ci_reruns": 0,
  "elapsed_seconds": null, "cost_usd": null
}
```

Outcomes: `progress`, `failed`, `complete`, `waiting`, `exhaustion`. Only failed
attempts require a bug/signature/approach. A truthful wait needs its observed
state pointer and next action, not an invented bug. `waiting` returns `wait`
(exit 3, no model): keep existing event monitoring until changed-state
`wake_evidence` permits a same-model retry. `exhaustion` with a valid recovery
handoff resumes on the same model, without counting as failed quality.

Use a stable task ID for retries of the same goal. A materially new finding
batch after task completion gets a new ID bound to its PR/HEAD/finding watermark;
never reset IDs merely because an attempt was slow or failed. Handoff routing
is keyed by task **and** phase so a prior completed fix cannot suppress or erase
a new fix task. Copy the full current phase record into the handoff before
transition; retain other tasks and phases under the existing locked writer.

 Use `new_evidence` for discoveries,
distinct failures repaired or a narrowed cause, with real source/log pointers.
Do not relabel repetition as progress. One bad answer, slow work, one failing
test, one review rejection or a retry count alone never upgrades a worker.
Useful progress continues on the same cheap model, without a fixed retry cap.

Two consecutive equivalent failures without new evidence trigger **diagnosis**,
not automatic escalation. Repeated materially poor patches that generated
review/CI churn also trigger diagnosis. Counters are per-attempt increments,
not cumulative totals. Do not send bad patches to paid reviewers to create
escalation evidence; paid review still requires its separate authorization.

A diagnosis cites `model`, `kind` (`stuck_bug` or `poor_patch_churn`), unique
`attempt_ids`, `evidence` pointers and `why_more_retries_unlikely`. Stuck-bug
escalation requires meaningful failed attempts on the same bug with different
approaches. Identify each method by a SHA-256 fingerprint of its actual normalized
operation/patch artifact and a `method_evidence` pointer, not its prose label.
Rewording `approach` never makes a distinct method. The diagnosing caller must
inspect the artifacts and record `approaches_verified:true`; different hashes
alone do not prove semantic novelty. Missing fingerprints/evidence keep the task
in diagnosis. Repeated identical commands are not meaningful attempts. Churn escalation
requires at least two evidenced poor patches with review/CI activity. A diagnosis
is task-local; old failures from another model do not immediately upgrade its
replacement. If supported, select the next eligible tier. An owner pin requires
an owner decision; no eligible higher tier retains a blocked recovery record.

## Before push, review and CI

Run appropriate local checks, resolve known findings, batch related changes and
compare the proposed tree with the last pushed tree. Persist their results as
evidence. `submission_allowed` is true only when all three request flags are
true: `local_checks_passed`, `distinct_changes`, `batched`. A false/unknown
result blocks a routine new push/review/CI request, not local diagnosis/retry.
The fixer (not just its spawning parent) refreshes the request **after editing**,
using actual local-check logs, current versus last-pushed tree and batch contents.
Persist the updated request/result and evidence pointers in its existing phase
record before pushing. A pre-spawn decision with false submission flags is not
post-edit verification. The Phase A/B push guards execute this check immediately
before a push; their prompts must carry the current request file pointer.
Run this block in a subshell and catch refusal in the caller: preserve the
unpushed SHA and recovery evidence, write the existing handoff, and print a
blocked exit report. Never mark a rejected submission ready for Phase B.

<!-- test-anchor: model-route-submission -->
```bash
# model-route-submission
: "${MODEL_ROUTE_REQUEST:?post-edit routing request required}"
MODEL_ROUTE_SH=""
for ROUTE_CANDIDATE in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/model-route.sh}" \
  "${HOME:+$HOME/.claude/scripts/model-route.sh}" \
  ".claude/scripts/model-route.sh"; do
  if [ -x "$ROUTE_CANDIDATE" ]; then MODEL_ROUTE_SH="$ROUTE_CANDIDATE"; break; fi
done
if [ -z "$MODEL_ROUTE_SH" ]; then
  echo "ERROR: model-route.sh not found (checked all three paths) — submission unavailable" >&2
  exit 5
fi
SUBMISSION_RESULT=$("$MODEL_ROUTE_SH" --input "$MODEL_ROUTE_REQUEST") || exit 5
jq -e '.submission_allowed == true' <<<"$SUBMISSION_RESULT" >/dev/null || exit 5
```

Do not use empty commits or unchanged pushes as routine retry progress. A
necessary reviewer-recovery exception follows its existing explicit workflow
and records why. This helper never satisfies or relaxes CI, substantive review,
thread resolution, AC verification or the merge gate.

## Measurement

Attach the actual runtime session/task/agent ID through `spend-telemetry-link.sh`
when available (Issue #1877); never infer an ID or cost. Record actual per-attempt
elapsed time, quality/check outcomes, completion, reviewer rounds and CI reruns.
Missing cost is null, not zero; known subtotal and complete total are separate.
The fixture trial report measures the deterministic router and its simulated
attempt histories. It does not measure model quality, model latency or savings.
Report live model trials separately, with their measured costs or unknowns.
Keep routine retries silent; surface only authority-requiring decisions, safety
events, genuine stalls and exhausted recovery, with actionable evidence.
