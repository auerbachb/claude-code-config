# Published pre-1642 spawn record fences — failure-classification counterfactuals.

<!-- test-anchor: old-pmm-spawn-record -->

```bash
NOW=$(date -u +%FT%TZ)
AGENT_SETS=()
IN_FLIGHT_SETS=()
# ONE loop per spawned PR — build that PR's entry AND its --set argument together,
# each using ONLY that PR's own head_sha. Never hoist head_sha into a shared
# variable reused across iterations or across a second loop — the last PR's SHA
# would silently overwrite every earlier PR's lock.
for N in $SPAWNED_PR_NUMS; do
  N_HEAD_SHA=$(jq -r '.head_sha' <<<"${GATE_BY_PR[$N]}")   # that PR's own tick-scoped $GATE
  # --first: one primary issue per agent entry. Default mode is set-valued
  # (issue #1492) and a two-line value would break the `jq --argjson` below.
  ISSUE_N=$("$PR_ISSUE_REF_SH" --first "$N" 2>/dev/null || echo null)
  AGENT_ID="pmm-fix-$N"
  # -c is load-bearing: the entry is interpolated into a --set argument below,
  # and jq's default pretty-print would embed newlines in it.
  ENTRY=$(jq -n -c --arg id "$AGENT_ID" --arg task "PMM fix PR #$N" --argjson issue "$ISSUE_N" \
    --argjson pr "$N" --arg launched "$NOW" --arg head_sha "$N_HEAD_SHA" \
    '{id:$id, task:$task, issue:$issue, pr:$pr, phase:"A", status:"spawned", launched:$launched, head_sha:$head_sha}')
  # Targeted per-key write — never a whole-map `--set '.active_agents=...'`.
  AGENT_SETS+=(--set ".active_agents[\"$AGENT_ID\"]=$ENTRY")
  IN_FLIGHT_SETS+=(--set ".pmm_in_flight.\"$N\"={\"skill\":\"phase-a-fixer\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$N_HEAD_SHA\",\"agent_id\":\"$AGENT_ID\"}")
done

# After the loop — ONE write carrying every per-key agent assignment plus the locks.
"$SESSION_STATE_SH" ${AGENT_SETS[@]+"${AGENT_SETS[@]}"} ${IN_FLIGHT_SETS[@]+"${IN_FLIGHT_SETS[@]}"}
```

<!-- test-anchor: old-subagent-spawn-record -->

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key)

# This spawn's active_agents entry, built FIRST so it can ride along in the one
# invocation below. -c is load-bearing: the entry is interpolated into a --set
# argument, and jq's default pretty-print would embed newlines in it. Details
# and the field contract are in 7.2 — it is built here only so that nothing
# about this launch reaches disk in two separate writes.
AGENT_ENTRY=$(jq -n -c --arg id "$AGENT_ID" --arg task "$TASK" \
  --argjson issue "{ISSUE_NUMBER}" --arg launched "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{id:$id, task:$task, issue:$issue, pr:null, phase:"A", status:"spawned", launched:$launched}')
AGENT_SET=(--set ".active_agents[\"$AGENT_ID\"]=$AGENT_ENTRY")

# A fresh pipeline replaces any terminal lifecycle's timestamp and PR link.
# Only an explicitly identified retry preserves this pipeline's original Start.
LAUNCHED_AT=""
if [[ "${SUCCESSOR_KIND:-}" == retry ]]; then
  LAUNCHED_AT=$("$SESSION_STATE_SH" \
    --get ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].started_at")
  [[ "$LAUNCHED_AT" == "null" ]] && LAUNCHED_AT=""
fi
if [[ -z "$LAUNCHED_AT" ]]; then
  LAUNCHED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  # ONE invocation carries every piece of spawn-time state — the pipeline
  # record, monitoring_active, AND this spawn's agent entry. A second call for
  # the agent would leave the pipeline active with no active_agents record
  # whenever that second call failed.
  # The claim holder from Step 6.0 rides in the same write (Step 8.1 renews with
  # it). Omitted when unknown — no claim helper, or no .holder in the JSON — and
  # a pipeline without one is simply never renewed.
  # Step 6.0 normally recorded both already; never reset a recorded
  # claim_renewed_at — that would hide a queued claim's real age.
  CLAIM_SET=()
  [[ -n "$CLAIM_HOLDER" ]] && CLAIM_SET=(
    --set ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].claim_holder=$(jq -cn --arg h "$CLAIM_HOLDER" '$h')")
  C_PREV=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].claim_renewed_at" 2>/dev/null) || C_PREV=""
  [[ -n "$CLAIM_HOLDER" && ( -z "$C_PREV" || "$C_PREV" == "null" ) ]] && CLAIM_SET+=(
    --set ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].claim_renewed_at=$LAUNCHED_AT")
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].started_at=$LAUNCHED_AT" \
    --set ".repos[\"$REPO_KEY\"].pipelines[\"{ISSUE_NUMBER}\"].pr=null" \
    ${CLAIM_SET[@]+"${CLAIM_SET[@]}"} \
    --set '.monitoring_active=true' \
    "${AGENT_SET[@]}"
else
  # Respawn: the launch record stands. Never re-null `.pr` either — that link is
  # the heartbeat's fallback to `pipeline_started_at` (Step 8). The agent entry
  # still rides along — a replacement agent needs its own record.
  "$SESSION_STATE_SH" --set '.monitoring_active=true' "${AGENT_SET[@]}"
fi
```
