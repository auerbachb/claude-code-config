# Cheapest-suitable worker routing and patient retries

Issue #1875. This contract governs unattended phase A/B/C, PM and read-only
worker launches. It does not change the running parent model, the owner's
interactive picker, permissions, tool allowlists, review independence or gates.

## Before each launch

Resolve `model-route.sh` through the usual shared-tool paths. Run it with
`--input <request.json>`. It makes no provider calls and changes no state.
Supply an explicit current runtime inventory, not guessed availability. The
cost ladder is Haiku → Sonnet → Opus. The router never recommends Fable as a
starting tier; outside an explicit owner choice, only speed mode reaches it — as the
escalation step above a stalled Opus worker, or by a reasoned parent choice. The run
mode and issue tier recommend the starting tier (see "Run mode and issue tier"). This is an ordinal cost policy,
not a dollar estimate or a claim that every task succeeds on Haiku. Actual
availability and capability win over the ladder. Source: [provider pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[subagent model/tool configuration](https://code.claude.com/docs/en/sub-agents).

**The router recommends; the launching thread decides (Issue #2449).** Choose the
cheapest suitable available model. The run mode and issue tier give a recommended
starting point; you decide what is suitable for this task and record a one-line
reason when you depart from the recommendation (see "Parent choice" below).

For each candidate confirm tool support, required context, the agent's unchanged
permission/tool restrictions, provider availability and budget/reserve controls.
`capable` means the tier suits the task, not that a first patch is guaranteed
correct. Unknown capability/availability is ineligible. Set `capable` to `true`
when the tier suits the task. Set `false` when your judgment is that it does not;
no proof is needed, and the router honours it as a recorded note. When a concrete
requirement is missing, also add a `capability_gap` (see "Capability gap" below). A provider
limit is handled by existing park/wake controls, never an excuse to buy another
tier or silently switch accounts. Preserve the existing reserve gate's own
freshness/unknown semantics; the routing helper does not reinterpret its marker.

Request shape (the inventory below is illustrative, not a live authorization):

```json
{
  "task": "issue-123", "phase": "A", "mode": "default", "tier": "Light",
  "launch_allowed": true, "permissions_preserved": true,
  "runtime": {"version": "2.1.312", "model_override_forced": false},
  "owner_model": null, "current_model": null, "parent_choice": null,
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

The result contains `action`, `model` (the model to launch), `recommended_model`
(what the table alone would launch, null when it would launch nothing), `choice`
(the parent choice record, null when none), `reason`, evidence IDs, metrics,
`capability_fallback` and `capability_gaps` (both always present, empty when
nothing applies). An invalid request (exit 2) returns only `action` `invalid`,
`model` null and `error`, with no capability fields. Exit
0 permits `start`, `retry`, `escalate`, or reports `complete`; only the first
three launch. Exit 3 (`wait`, `diagnose`, `owner_decision`, `blocked`) launches nothing;
persist the pending work and recover or surface an owner-only decision as
appropriate. Exit 2 means invalid/unreadable input: retain the error and repair
the request, never fall back to a premium literal.

### Run mode and issue tier

`mode` is the PM run mode read with `run-mode.sh get` (`run-modes.md`); absent or
unrecognized reads as `default`. `tier` is the issue's Light, Standard or Heavy
tier. This is the single rule for resolving it: take it from the issue's estimate
via `estimate-resolve.sh` (`time-estimates.md` tier vocabulary; XL counts as
Heavy). When it cannot be resolved (the issue is unestimated or the helper fails),
omit `tier` or send null: the request routes as Standard and the decision's
`reason` says "Tier unresolved; routed as Standard". Callers never reject a launch
for a missing tier. An unrecognized tier value is invalid (exit 2). The decision
echoes both fields. `/subagent`, `/pm` and `pmm-act` point here rather than
restating it.

| Mode | Light | Standard | Heavy | Escalation after a failure |
|------|-------|----------|-------|----------------------------|
| default | Haiku | Sonnet | Opus | two equivalent failures plus diagnosis |
| speed | Sonnet | Opus | Opus | one failed attempt without new evidence moves up; an Opus worker that moves up goes to Fable |
| cheap | Haiku | Haiku | Haiku | two equivalent failures plus diagnosis |

Fallback when a preferred tier is unavailable or ineligible: the next entry in
that row's preference order, named in `reason`. The table never recommends Fable as
a starting tier; only an owner choice, or a parent choice in speed mode, starts there. Speed mode escalates one step at a time: Sonnet
to Opus, then Opus to Fable (only while Fable is eligible). Default and cheap
escalate on diagnosis only and never reach Fable unless the owner pins it. A Fable
worker started by an owner pin keeps its model on retries in speed mode and is
blocked in default or cheap mode. An explicit owner pin wins in every mode, an
unavailable pin still blocks, and budget, reserve, launch, review and merge gates
are unchanged. A mode change affects only later launches.

The escalation column is the point where the parent **must** reconsider (the
router returns `diagnose` in default and cheap modes), not the only point where it
**may**: after any unsatisfactory attempt the parent can move the retry with a
`parent_choice` and a reason.

### Parent choice

Add `"parent_choice": {"model": "sonnet", "reason": "<one line>"}` to launch on a
model other than the recommendation, lower or higher. No missing tool and no
failed attempt is needed first. The rules:

- `reason` is required: one nonblank line (at most 500 characters). A choice
  without one is refused as invalid (exit 2) with an error naming
  `parent_choice.reason`; one naming an unknown model is refused the same way with
  an error naming `parent_choice`.
- The chosen row must pass the same eligibility as any other: available, within
  budget and reserve, with evidence, and not `capable: false`. An ineligible
  choice blocks (exit 3); the router never substitutes silently.
- Fable stays owner-only outside speed mode: a parent choice of Fable in default
  or cheap mode blocks. In speed mode it is allowed.
- An owner pin wins. The choice is kept in the record with `applied: false` and
  `reason` says the pin won.
- Launch gates, runtime checks, `complete` and an unchanged `wait` are decided
  first; a parent choice never launches past them.
- With no attempts the action is `start`; on a retry it is `retry` when the
  model is unchanged and `escalate` (a fresh context on the chosen model, up or
  down) when it changes. At the diagnosis threshold a parent choice is the
  recorded reconsideration and launches.

The decision records `recommended_model`, the chosen `model`, and `choice`
`{by: "parent", model, reason, applied}`, plus the recommendation's own
`capability_fallback` and `capability_gaps`; `reason` reads `Parent choice <model>
(recommended <model>; router action <action>): <reason>`. That record, persisted
before launch, is where each departure stays visible afterwards.

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

## Capability gap

A tier marked `"capable": false` is excluded: it is the caller's judgment that the
tier does not suit the task (Issue #2449 replaced the proof requirement of
Issue #2301). When the reason is a concrete missing requirement, record it on the
same inventory row:

```json
"capability_gap": {
  "kind": "tool",
  "detail": "needs the repo-local MCP tool the cheaper tier cannot call",
  "evidence": "path/to/tool-requirement-check.json"
}
```

- `kind` is one of `tool`, `context` or `permissions`.
- `detail` names the missing requirement. `evidence` points to the check that
  shows it. Both must be nonblank strings.
- A valid gap excludes that tier. The decision lists it in `capability_gaps`
  and, when a higher tier is chosen, `reason` names the skipped tier and `kind`.
- A `false` with no gap, or with a missing or malformed one (bad `kind`, blank
  field, or a non-object), is **honoured as a recorded note**. The tier is
  skipped: a fresh start takes the next eligible tier in the mode's start order
  for the issue tier (the ladder row above), and `capability_fallback` names the
  tier with `basis` `missing` or `malformed`. `reason` says `<tier> skipped on
  caller judgment` for every such tier. When every tier is judged unsuitable the
  route blocks (exit 3).
- A retry whose **current** tier is marked `false` without a gap moves to the
  next eligible tier above it (`escalate`), after one attempt and in any mode;
  no diagnosis is needed. With nothing eligible above, it blocks.
- `capable: true` ignores any stray `capability_gap`. A missing, null or
  non-boolean `capable` stays ineligible, as before.
- An owner pin keeps its selection. A `false` without a gap on the pinned row is
  recorded in `capability_fallback` (`Owner pin kept <tier>`), not treated as a
  blocker. A valid gap on the pinned row blocks (exit 3), lists it in
  `capability_gaps`, and never substitutes another tier. A retry whose current
  tier has a valid gap blocks the same way rather than moving to another tier,
  unless a `parent_choice` names another eligible model: that explicit, reasoned
  move is not a silent substitution.

Name the missing requirement when there is one; otherwise your judgment is
enough. To pick a specific model rather than skip a tier, use `parent_choice`.

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
Set the Agent call's explicit `model` to the decision's `model` (the parent's
choice when one was applied, else the recommendation), keeping its existing
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
New records are created carrying the lowercased `owner_repo` (a conflicting `HANDOFF_JSON.owner_repo` is refused); Phase C repairs an older record that lacks it with `handoff-state.sh --seed-owner`. Each literal assignment uses the handoff helper's lock; write the completion marker last. Never read/overwrite the whole existing record outside that lock.

<!-- test-anchor: routed-handoff-write -->
```bash
# routed-handoff-write
: "${MODEL_ROUTE_RECORD:?current routing record required}" "${OWNER_REPO:?repo required}" "${PR_NUMBER:?PR required}"
jq -e '.request.task == .decision.task and .request.phase == .decision.phase' <<<"$MODEL_ROUTE_RECORD" >/dev/null || exit 5
jq -e 'type == "object" and (.phase_completed|type == "string") and (keys | all(test("^[A-Za-z_][A-Za-z0-9_]*$")))' <<<"$HANDOFF_JSON" >/dev/null || exit 5
jq -e --arg owner "$OWNER_REPO" '(has("owner_repo") | not) or (.owner_repo | type == "string" and ascii_downcase == ($owner | ascii_downcase))' <<<"$HANDOFF_JSON" >/dev/null || exit 5
ROUTED_HANDOFF_ASSIGNMENT=$(jq -nr --argjson route "$MODEL_ROUTE_RECORD" \
  '".model_routing[" + ($route.request.task|tojson) + "][" + ($route.request.phase|tojson) + "]=" + ($route|tojson)') || exit 5
ROUTED_OWNER_SEED=$(jq -nc --arg owner "$OWNER_REPO" '{owner_repo: ($owner | ascii_downcase)}') || exit 5
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --init "$PR_NUMBER" "$ROUTED_OWNER_SEED" || exit 5
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --require-existing --set "$PR_NUMBER" "$ROUTED_HANDOFF_ASSIGNMENT" || exit 5
ROUTED_METADATA_ROWS=$(jq -c 'to_entries[] | select(.key != "model_routing" and .key != "phase_completed" and .key != "owner_repo")' <<<"$HANDOFF_JSON") || exit 5
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
phases retain their own routes.

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
test, one review rejection or a retry count alone never upgrades a worker
**automatically**; the parent may still move it on its own reading of the result
with a `parent_choice` and a reason (see "Parent choice").
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
