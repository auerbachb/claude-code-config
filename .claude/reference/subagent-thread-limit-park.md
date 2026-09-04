# Subagent-thread usage-limit park (reactive) — issue #1618

**Scope.** The single source of truth for what a thread running Phase A/B/C
subagents does when the account's usage window closes underneath it: how the
signal is recognised, how the board is parked, how the wake is armed, how the
parked pipelines resume, and how an interrupted session re-arms. Rule files and
skills point here; the procedure is not restated anywhere else.

This is the **reactive** leg only — a kill has already landed. Consulting the
usage horizon *before* the wall is issue #1619 and is deliberately absent here.

**One park record, one wake class, one resume route.** Everything below reuses
`/pm` day mode's 2D.6 machinery and the shared `.repos["<key>"].day` park slot.
There is no second park record, no second wake class, and no second resume
command. What is new is only that a *subagent-running* thread — `/subagent`, or
any coding thread babysitting its own PR — can now be the path that parks, and
that the wake resumes dead Phase A/B/C pipelines phase-aware instead of
re-arming a live runtime ID.

**Quota authority is unchanged.** `safety.md` §"Anthropic Quota & Spend
Authority" binds as written: only the runtime's own structured classification
reaches this document. Nothing here estimates tokens, spend, or remaining
quota, and no decision below is gated on a locally-computed figure.

---

## 1. Detection — a limit death is not a crash

Today a subagent that returns no exit report is a crash: `phase-protocols.md`
tells the parent to report it and ask before respawning. That is right for an
agent that died on its own and wrong for an account-wide wall, where the
siblings are about to die the same way and the ask reaches a human who cannot
help until the window reopens.

**A usage-limit signal is a structured runtime classification, never a text
match.** Same rule as 2D.6. Exactly three shapes qualify:

1. The runtime's failure payload for the dead subagent, or the parent's own
   `StopFailure` payload, carrying `error == "rate_limit"`,
   `error.type == "rate_limit_error"`, `error_type == "rate_limit_error"`, or
   the harness's own structured background-agent failure code for a reached
   session limit (`session_limit_reached`).
2. The same classification on the parent's turn rather than a child's.
3. A fresh `~/.claude/usage-limit-last.json` breadcrumb — `reason ==
   "rate_limit"`, written by the `usage-limit-record.sh` StopFailure hook from
   the runtime's own `error == "rate_limit"` — whose `recorded_at` falls inside
   the corroboration window (default 15 minutes). This is a **structured**
   record of the runtime's classification, not a text match, which is why it
   qualifies; it exists because the agent-failure notification the parent
   receives may carry no payload at all.

The banner prose — `Background agent failed · Session limit reached`, "out of
tokens", "weekly limit" — **never** qualifies on its own. Those phrases also
appear on context-window exhaustion and on unrelated upstream errors, which is
precisely the misclassification that would park a whole board because one agent
overran its context.

**The reset time comes from the confirmed signal only.** Answering the issue's
open question: the breadcrumb may confirm *that* the wall was hit, but it may
**not** supply *when* the window reopens. `usage-limit-last.json` carries no
machine-readable reset field — the vendor's `resets 3:50pm` lands inside
`error_details`, a truncated free-text string, and parsing a time out of it is
exactly the text-only match this section forbids. So a corroborated-only park
takes 2D.6's missing-reset branch: the 60-minute `rolling_window` default. The
wake is then early rather than wrong, and an early wake that re-hits the limit
is what the thrash guard in §4 exists to absorb.

<!-- test-anchor: subagent-limit-classify -->

```bash
# Inputs (all optional; absent ones simply do not vote):
#   FAILURE_JSON  the runtime's structured failure payload for the dead subagent
#                 or for the parent's own turn. Never a chat string.
#   BREADCRUMB    path to usage-limit-last.json (default ~/.claude/…).
# Outputs: LIMIT_SIGNAL (true|false), LIMIT_SOURCE, RESET_EPOCH, LIMIT_KIND,
#          PARKED_UNTIL.
LIMIT_SIGNAL=false
LIMIT_SOURCE=""
NOW_EPOCH=$(date -u +%s)

# 1. Structured classification on the failure payload. Field lookups only — the
#    strings below are compared against a FIELD's value, never searched for in
#    prose, so a context-exhaustion message that happens to say "limit" cannot
#    reach this branch.
if [[ -n "${FAILURE_JSON:-}" ]]; then
  # `.error` is a string in one runtime shape and an object in another, so every
  # lookup is guarded by `objects`/`strings`: `"rate_limit" | .type` is a jq
  # ERROR, and an unguarded chain would take the whole program non-zero and
  # silently discard the very signal the string shape carries.
  LIMIT_CLASS=$(printf '%s' "$FAILURE_JSON" | jq -r '
    if type != "object" then "" else
    [ (.error        | strings),
      (.error        | objects | .type | strings),
      (.error_type   | strings),
      (.failure_code | strings),
      (.subtype      | strings) ]
    | map(select(. == "rate_limit" or . == "rate_limit_error"
                 or . == "session_limit_reached"))
    | first // "" end' 2>/dev/null) || LIMIT_CLASS=""
  if [[ -n "$LIMIT_CLASS" ]]; then
    LIMIT_SIGNAL=true; LIMIT_SOURCE="signal:$LIMIT_CLASS"
  fi
fi

# 2. Corroboration: the recorder hook's durable copy of the same runtime
#    classification, when the notification itself carried nothing. Bounded by
#    age — a breadcrumb from this morning describes a window that has already
#    reopened, and treating it as live would park a healthy board.
BREADCRUMB="${BREADCRUMB:-$HOME/.claude/usage-limit-last.json}"
BREADCRUMB_MAX_AGE="${CLAUDE_LIMIT_BREADCRUMB_MAX_AGE_SECONDS:-900}"
[[ "$BREADCRUMB_MAX_AGE" =~ ^[0-9]+$ ]] || BREADCRUMB_MAX_AGE=900
if [[ "$LIMIT_SIGNAL" != true && -r "$BREADCRUMB" ]]; then
  CRUMB_REASON=$(jq -r '.reason // ""' "$BREADCRUMB" 2>/dev/null) || CRUMB_REASON=""
  CRUMB_AT=$(jq -r '.recorded_at // ""' "$BREADCRUMB" 2>/dev/null) || CRUMB_AT=""
  if [[ "$CRUMB_REASON" == "rate_limit" && -n "$CRUMB_AT" ]]; then
    CRUMB_EPOCH=$(date -u -d "$CRUMB_AT" +%s 2>/dev/null \
                  || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$CRUMB_AT" '+%s' 2>/dev/null) || CRUMB_EPOCH=""
    if [[ "$CRUMB_EPOCH" =~ ^[0-9]+$ ]] \
       && (( NOW_EPOCH - CRUMB_EPOCH >= 0 )) \
       && (( NOW_EPOCH - CRUMB_EPOCH <= BREADCRUMB_MAX_AGE )); then
      LIMIT_SIGNAL=true; LIMIT_SOURCE="breadcrumb"
    fi
  fi
fi

# 3. Reset time — from the confirmed SIGNAL only, never from the breadcrumb and
#    never from local accounting. Same validation 2D.6 applies: a non-integer,
#    zero, or past value is no reset time at all.
SIGNAL_RESET_EPOCH=""
if [[ "$LIMIT_SOURCE" == signal:* && -n "${FAILURE_JSON:-}" ]]; then
  SIGNAL_RESET_EPOCH=$(printf '%s' "$FAILURE_JSON" | jq -r '
    if type != "object" then "" else
    [ (.error | objects | .reset_epoch     | numbers),
      (.reset_epoch                        | numbers),
      (.error | objects | .resets_at_epoch | numbers) ] | first // "" end' 2>/dev/null) || SIGNAL_RESET_EPOCH=""
fi
if [[ "$SIGNAL_RESET_EPOCH" =~ ^[0-9]+$ ]] && (( SIGNAL_RESET_EPOCH > NOW_EPOCH )); then
  RESET_EPOCH="$SIGNAL_RESET_EPOCH"
else
  RESET_EPOCH=$(( NOW_EPOCH + 3600 ))
fi
HORIZON_SECONDS=$(( RESET_EPOCH - NOW_EPOCH ))
LIMIT_KIND="rolling_window"
[ "$HORIZON_SECONDS" -gt $(( 8 * 3600 )) ] && LIMIT_KIND="weekly"
PARKED_UNTIL=$(date -u -d "@$RESET_EPOCH" +%FT%TZ 2>/dev/null || \
               date -u -r "$RESET_EPOCH" +%FT%TZ)
printf 'LIMIT_SIGNAL=%s\nLIMIT_SOURCE=%s\nLIMIT_KIND=%s\nRESET_EPOCH=%s\nPARKED_UNTIL=%s\n' \
  "$LIMIT_SIGNAL" "$LIMIT_SOURCE" "$LIMIT_KIND" "$RESET_EPOCH" "$PARKED_UNTIL"
```

**`LIMIT_SIGNAL=false` changes nothing.** The dead subagent is a crash, and
`phase-protocols.md`'s existing path owns it unchanged: report to the user, ask
before respawning. The limit path is an *exception carved out of* that path,
never a replacement for it.

---

## 2. Claim the park before shutting anything down

Order matters, and it is 2D.7's order rather than 2D.6's: **claim, then stop**.
A lost race costs nothing when the claim comes first, whereas stopping the
board first and then losing leaves a stopped board with no park record and no
wake. The account is already refusing work, so there is nothing to land and
nothing is lost by claiming immediately.

Read the thrash counter before the claim — the claim carries it — and fail
closed when it cannot be read, exactly as 2D.6 does. A corrupt or lock-timed
count cannot be reset to 0 without handing a hot loop a free pass.

<!-- test-anchor: subagent-limit-park-claim -->

```bash
# Inputs: SESSION_STATE_SH, REPO_KEY, PARKED_UNTIL, LIMIT_KIND (from §1).
# Outputs: PARK_CLAIM=won|adopted|error, NEW_HITS.
HITS_RC=0
PRIOR_HITS=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits" 2>/dev/null) || HITS_RC=$?
[ "$HITS_RC" -eq 3 ] && PRIOR_HITS=0   # no state file — first limit hit ever
if [[ "$HITS_RC" -ne 0 && "$HITS_RC" -ne 3 ]]; then
  # Fail closed. Not a park failure to paper over: an unreadable count is the
  # one input that makes the thrash guard unenforceable.
  echo "PARK_CLAIM=error rc=hits:$HITS_RC"
elif [[ -n "$PRIOR_HITS" && "$PRIOR_HITS" != "null" && ! "$PRIOR_HITS" =~ ^[0-9]+$ ]]; then
  # READABLE but malformed is not the same as absent. Coercing it to 0 would
  # silently reset the thrash guard on exactly the corrupted state that guard
  # exists to survive, so it fails closed like an unreadable count.
  echo "PARK_CLAIM=error rc=hits:malformed"
else
  # The EMPTY string keeps 2D.6's normalisation, deliberately: 2D.7 Step 3's
  # claim writes one while the record is still being assembled, and both paths
  # depend on it reading as a fresh counter rather than as corruption.
  [[ "$PRIOR_HITS" =~ ^[0-9]+$ ]] || PRIOR_HITS=0
  NEW_HITS=$(( PRIOR_HITS + 1 ))
  # One atomic write (#1445): the cause is the claim AND the record completes with
  # it, so there is no window in which the slot is owned but the metadata is not
  # written. `limit_cause` is the CAS field precisely because it is null until
  # exactly one path — 2D.6, 2D.7, another thread, or this one — claims it.
  PARK_CLAIM_RC=0
  "$SESSION_STATE_SH" \
    --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=\"$PARKED_UNTIL\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"$LIMIT_KIND\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
    --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=$NEW_HITS" \
    >/dev/null 2>&1 || PARK_CLAIM_RC=$?
  case "$PARK_CLAIM_RC" in
    0) echo "PARK_CLAIM=won" ;;
    7) echo "PARK_CLAIM=adopted" ;;  # day mode or a sibling thread parked first
    *) echo "PARK_CLAIM=error rc=$PARK_CLAIM_RC" ;;
  esac
fi
```

- **`won`** → continue to §3. This thread owns the park and will arm the wake.
- **`adopted`** → a park already exists (day mode's 2D.6/2D.7, or a concurrent
  thread on the same repo). **Adopt it: do not open a second one.** Still run §3
  — the pipelines this thread was running are not recorded anywhere else, and
  the wake that is already armed has no way to know about them. Then skip §4
  entirely: no second wake, no second Monitor, no second chat line. This is the
  #1428 / #1445 adoption contract, reached through the same `limit_cause`
  compare-and-set both of those paths use. **The adopted wake still resumes these
  pipelines**: day mode's wake fires `/pause-resume --generation`, whose Step 5
  relaunch reads the very per-PR records §3 writes and follows §5 directly. That
  is why §3 runs on the adoption path and why the wake command may differ
  between owners without becoming a second resume route — both ends read one set
  of records.
- **`error`** → fail closed. Park nothing, arm nothing, stop nothing, and say in
  one line that the limit was recognised but the park record could not be
  written, so manual wind-down is needed. A shutdown with no durable record is
  the one outcome worse than not parking.

**Then stop the remaining subagents.** Activate the execution gate
(`execution-pause.sh --activate --command pause --window-minutes 0`) and run
`/pause` Steps 2–7 with `--window 0`, **skipping only Step 1's `.refill.paused`
write**. That carve-out is 2D.6's, for 2D.6's reason: the field is human-owned,
and an automatic wake that cleared it would lift a pause the user set by hand.
`--window 0` is right here for the same reason it is right in 2D.6 — the
account is already refusing work, so `/pause` Steps 4–5 have nothing to land.

---

## 3. Record each parked pipeline so resume is phase-aware

The park record holds **one** wake for the repo, but a thread can have several
pipelines in flight, each at a different phase. Resume must put each back where
it was — Phase B for a pipeline whose Phase A had already pushed — not restart
it from scratch.

For every pipeline this thread was running, write a per-PR park record in the
existing token-exhaustion shape, with `handoff_reason: "usage_limit_park"`:

<!-- test-anchor: subagent-limit-pipeline-record -->

```bash
# Inputs: SESSION_STATE_SH, REPO_KEY, PR_NUM, PARK_PHASE (A|B|C),
#         PARK_HEAD_SHA, PARK_NEEDS, PARK_REMAINING (JSON array), PARKED_UNTIL.
PARK_PR_JSON=$(jq -c -n \
  --arg phase "$PARK_PHASE" \
  --arg needs "$PARK_NEEDS" \
  --arg sha   "$PARK_HEAD_SHA" \
  --arg until "$PARKED_UNTIL" \
  --argjson remaining "${PARK_REMAINING:-[]}" \
  '{phase: $phase, needs: $needs, handoff_reason: "usage_limit_park",
    head_sha: $sha, parked_until: $until, remaining_work: $remaining}')
PR_PARK_RC=0
"$SESSION_STATE_SH" \
  --set ".repos[\"$REPO_KEY\"].prs[\"$PR_NUM\"].usage_limit_park=$PARK_PR_JSON" \
  --set ".repos[\"$REPO_KEY\"].prs[\"$PR_NUM\"].handoff_reason=\"usage_limit_park\"" \
  >/dev/null 2>&1 || PR_PARK_RC=$?
[ "$PR_PARK_RC" -eq 0 ] && echo "PR_PARK=$PR_NUM:recorded" \
                        || echo "PR_PARK=$PR_NUM:error rc=$PR_PARK_RC"
```

**A `PR_PARK=<N>:error` line is a lost pipeline, not a logged warning.** The
resume paths find parked pipelines *only* by scanning `.prs[*]` for
`handoff_reason == "usage_limit_park"` (§5), and Probe F reads the same records,
so a PR whose write failed is invisible to both: it stays killed while every
parked sibling comes back. Never count that PR as parked. Name it explicitly in
the park report — `unparked: PR <N> (rc=<rc>) — relaunch manually` — carry the
failure into the park's own summary rather than the shell's stdout alone, and
retry the write once before reporting, since `session-state.sh` exits **6** on a
lock timeout, which is transient. A park that silently drops a pipeline is worse
than no park: the wake fires, the board resumes, and one PR never comes back.

`handoff_reason` is written at the PR entry's top level as well as inside the
record because that is the key `/go-on` Probe D already scans; the nested
`usage_limit_park` object carries the resume detail without changing the shape
Probe D matches on.

**Confirm the on-disk handoff before trusting the recorded phase.** State can
lie about a phase that never finished; the handoff file is the corroborating
evidence, exactly as Probe D corroborates a token-exhaustion entry:

```bash
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUM" | jq -r '.phase_completed'
```

A pipeline whose Phase A had completed reads `"A"`, and resume relaunches
**Phase B** — the PR #1616 case. A missing or unreadable handoff is
reconstructed from GitHub before the park record is trusted
(`phase-protocols.md` Phase A step 5 already owns that reconstruction); a park
record naming a phase the handoff cannot support is reported, not resumed.

**Verify before recording, so resume never has to guess.** The phase written
here is the one a relaunch will act on, so it is corroborated against the
handoff *at park time* as well as at resume time, and the last durable milestone
— the PR number and pushed `head_sha` — is recorded with it. That is what stops
a resume from re-running a phase whose work already landed: a fresh Phase A over
an existing PR, or a second Phase C after a merge.

A failed per-PR write does **not** abort the park — the repo-level record and
its wake are already durable and are what stops the board. It is reported in the
park line, and that pipeline resumes through the ordinary `unplanned` lane
instead of the phase-aware one.

---

## 4. Arm the wake (owner of the park only)

Skip this whole section on `PARK_CLAIM=adopted` — the winner's wake is the only
one that may exist.

**Thrash guard, identical to 2D.6.** `MAX_LIMIT_HITS = 3`. At the cap the board
stays parked permanently with no wake and one line, because a wake that keeps
re-hitting the same wall is a hot loop against the account that is already
refusing work.

**Weekly caps never get an in-session wake.** No Monitor can outlast days, and
continuing would incur overage charges. Park, print one line, and stop.

<!-- test-anchor: subagent-limit-wake-arm -->

```bash
# Inputs: NEW_HITS, LIMIT_KIND, RESET_EPOCH, PARKED_UNTIL (from §1–§2).
# Outputs: WAKE=armed|capped|weekly, WAKE_SLEEP, WAKE_GENERATION, WAKE_COMMAND.
MAX_LIMIT_HITS=3
WAKE_SLEEP=""; WAKE_GENERATION=""; WAKE_COMMAND=""
if [ "$LIMIT_KIND" = weekly ]; then
  WAKE=weekly
  echo "stopped — weekly cap reached; pipelines parked. Resume manually with /go-on when the window reopens at $PARKED_UNTIL"
elif [ "$NEW_HITS" -ge "$MAX_LIMIT_HITS" ]; then
  WAKE=capped
  echo "Parked (usage limit) — $NEW_HITS consecutive limit hits on resume; staying parked to avoid a hot loop. Resume manually with /go-on."
else
  WAKE=armed
  WAKE_SLEEP=$(( RESET_EPOCH - $(date -u +%s) + 120 ))   # reset + 2 min buffer
  [ "$WAKE_SLEEP" -lt 1 ] && WAKE_SLEEP=1
  BACKOFF_MULT=$(( 1 << (NEW_HITS - 1) ))                # 2^(NEW_HITS-1), as 2D.6
  WAKE_SLEEP=$(( WAKE_SLEEP * BACKOFF_MULT ))
  WAKE_GENERATION="limit-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  WAKE_COMMAND="/go-on --generation $WAKE_GENERATION"
fi
printf 'WAKE=%s\nWAKE_SLEEP=%s\nWAKE_GENERATION=%s\n' "$WAKE" "$WAKE_SLEEP" "$WAKE_GENERATION"
```

On `WAKE=armed`, arm **one** persistent `Monitor` running the same one-shot
shape 2D.6 arms — `while sleep "$WAKE_SLEEP"; do printf '%s\n' "$WAKE_COMMAND"; break; done`
— and publish its identity immediately. `/go-on`, not `/pause-resume`, because
only `/go-on` can relaunch a dead Phase A/B/C pipeline at its recorded phase;
`/pause-resume` re-arms live runtime IDs and would leave every parked pipeline
stopped. It remains the same wake *class* in the same registry, so `/pause`
Step 2 item 4 and `/pause-resume` Step 5 tear it down unchanged.

<!-- test-anchor: subagent-limit-wake-publish -->

```bash
# Publish the identity pair as ONE compare-and-set from null (#1445), so the
# publication is itself the last mutual-exclusion point: a kill or a day-mode
# park that armed a wake inside the shutdown window takes this to exit 7 and
# this thread stands down instead of registering a second wake over its ID.
PUBLISH_RC=0
"$SESSION_STATE_SH" \
  --cas ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=$LIMIT_MONITOR_TASK_ID" --expect null \
  --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=\"$WAKE_GENERATION\"" \
  >/dev/null 2>&1 || PUBLISH_RC=$?
case "$PUBLISH_RC" in
  0) echo "WAKE_PUBLISH=ok" ;;
  7) echo "WAKE_PUBLISH=superseded" ;;  # another wake owns the slot — stop ours
  *) echo "WAKE_PUBLISH=error rc=$PUBLISH_RC" ;;
esac
```

- **`ok`** → done. One line: `parked until {PARKED_UNTIL} — usage window; N pipeline(s) resume automatically`.
- **`superseded`** → `TaskStop` the Monitor just armed, using the ID in hand, and
  say nothing further. The other wake is in charge and the per-PR records from
  §3 are what it will resume.
- **`error`** → `TaskStop` the Monitor with the ID in hand, then **release the
  whole claim in one write, gated on still owning it** —
  `--cas '.repos["<key>"].day.limit_cause=null' --expect '"reactive"'` composed
  with `--set` writes nulling `parked_until`, `limit_kind`, and
  `limit_probe_fires_remaining`. Clearing `parked_until` alone is not enough:
  `limit_cause` is the compare-and-set field every parker claims through, so a
  cause left standing means no future park — this thread's, day mode's, or a
  sibling's — can ever win the compare again, and the board is permanently
  unparkable while reading as unparked. Gating on `"reactive"` is what keeps the
  release from clearing a park that landed meanwhile: exit 7 means someone else
  owns the record now, so clear nothing and stand down. Name the unrecorded task
  ID in the message, exactly as 2D.6 does.

---

## 5. Resume — `/go-on --generation`

The wake fires `/go-on --generation <id>`. `/go-on` validates the generation
against `.repos["<key>"].day.limit_resume_generation` before touching any gate
(a stale, mismatched, or unreadable generation is a silent no-op), then reads
the per-PR park records from §3, reopens the execution gate through the existing
`/pause-resume` delegation, and relaunches each parked pipeline from its handoff
file at the recorded phase. Full contract: `/go-on` Steps 0.1a and 0.6.

**Every launch gate still binds.** A relaunch is a launch: before starting each
parked pipeline, re-read the full stop-control set from `phase-protocols.md`
§"Launch gate before every successor" — repo `refill.paused`, the execution
pause, and the armed-deadline decline of `/subagent` Step 7 — plus the pipeline
ceiling and the repo-wide `active_work_cap`. A record that fails any gate is
**queued, not launched**, and its `usage_limit_park` flag stays set so a later
resume still finds it. A window reopening is not a licence to dispatch past the
limits that bound every other launch.

**A live parent still wins.** When a parent orchestrator is running, its
`phase-protocols.md` replacement path is the preferred relaunch and `/go-on`
says so rather than racing it — the same rule the token-exhaustion lane already
follows. `/go-on` relaunches only when no live parent holds the pipeline.

**Either wake reaches the same relaunch.** `/go-on --generation` runs the lane
above; `/pause-resume --generation` — the wake day mode arms — reaches it
through its own Step 5, which relaunches parked pipelines from these records
directly rather than calling `/go-on` back (that would be a cycle, since
`/go-on`'s park lane delegates to `/pause-resume` for the gate). One set of
records, two entry points, no second resume route.

**Claim each PR before relaunching it.** The per-PR records are repo-scoped, so
two threads resuming the same repo would otherwise both relaunch the same
pipeline. `/pause-resume` Step 5 owns the transition — a locked flip of
`handoff_reason` from `usage_limit_park` to `usage_limit_relaunching`, rolled
back on a blocked or failed launch — and any other route into these records
takes the same claim.

**Resume clears the park.** `/pause-resume` Step 5's `retire_limit_park` clears
the six `.day` fields in one write; the resuming thread additionally clears each
`.prs["N"].usage_limit_park` / `handoff_reason` it relaunched, and resets
`consecutive_limit_hits` to 0 once a relaunched pipeline completes a phase
without re-hitting the limit. A record left behind would make the next
recovery pass re-arm a wake for a park that has already ended.

---

## 6. Recovery — session start and post-compaction

An in-session `Monitor` dies with its session. A park is durable, so an
interrupted session must re-arm the wake or the board stays parked forever —
which is exactly what happened on 2026-09-03 with PR #1616.

Run this at session start and in `monitor-mode.md`'s Post-Compaction Recovery,
in any thread that runs subagents. It mirrors `/pm` 2D.1(b+) / 2D.5 exactly,
including their exit-code discipline: `0` is the stored value, `3` means no
state file has ever been written, **anything else is unreadable and fails
closed** — an unreadable `parked_until` is never "no park pending", because a
lock timeout can hide an active park and let this thread dispatch into a window
that is still closed.

<!-- test-anchor: subagent-limit-park-recovery -->

```bash
# Inputs: SESSION_STATE_SH, REPO_KEY. Output: PARK_RECOVERY=<verdict>.
read_day() {  # read_day <field> -> DAY_VALUE, DAY_RC
  DAY_RC=0
  DAY_VALUE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.$1" 2>/dev/null) || DAY_RC=$?
  [ "$DAY_RC" -eq 3 ] && DAY_VALUE="null"
}
read_day parked_until; PARKED_UNTIL="$DAY_VALUE"; PU_RC="$DAY_RC"
read_day limit_kind;   PARK_KIND="$DAY_VALUE";   LK_RC="$DAY_RC"
read_day limit_probe_fires_remaining; PARK_FIRES="$DAY_VALUE"; PF_RC="$DAY_RC"
if [[ ( "$PU_RC" -ne 0 && "$PU_RC" -ne 3 ) || ( "$LK_RC" -ne 0 && "$LK_RC" -ne 3 ) \
      || ( "$PF_RC" -ne 0 && "$PF_RC" -ne 3 ) ]]; then
  echo "PARK_RECOVERY=unreadable"      # fail closed: re-arm nothing, dispatch nothing
elif [[ -z "$PARKED_UNTIL" || "$PARKED_UNTIL" == null ]]; then
  echo "PARK_RECOVERY=none"            # no park — continue session start normally
else
  PARK_EPOCH=$(date -u -d "$PARKED_UNTIL" +%s 2>/dev/null \
               || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PARKED_UNTIL" '+%s' 2>/dev/null) || PARK_EPOCH=""
  # `-u` on the BSD fallback too: without it macOS reads the Z timestamp as local
  # time, so an ET machine sees every park as four hours longer than it is.
  if [[ ! "$PARK_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "PARK_RECOVERY=unreadable"
  elif [ "$PARK_EPOCH" -le "$(date -u +%s)" ]; then
    echo "PARK_RECOVERY=expired"       # window reopened — resume via /go-on
  elif [ "$PARK_KIND" != "rolling_window" ]; then
    echo "PARK_RECOVERY=manual"        # weekly cap, or an unrecognised kind
  elif [[ "$PARK_FIRES" =~ ^[1-9][0-9]*$ ]]; then
    # A pre-emptive park with fires LEFT (#1445): re-arm 2D.7's probe Monitor
    # with THAT count, never a fresh bound — re-arming twelve on every restart
    # is how a bounded probe becomes an unbounded one.
    echo "PARK_RECOVERY=rearm_probe fires=$PARK_FIRES"
  elif [[ "$PARK_FIRES" =~ ^-?[0-9]+$ ]]; then
    echo "PARK_RECOVERY=manual"        # 0 or -1: the bound is spent or absent
  else
    echo "PARK_RECOVERY=rearm"         # null: the reset time is known
  fi
fi
```

- **`rearm_probe`** → this repo's park is 2D.7's pre-emptive one with fires left,
  not a reactive park at all. Re-arm **that** wake — `/pm` 2D.7's bounded probe
  `Monitor` with the recorded count — and leave the sleep-until-reset shape
  alone. Reading a live probe bound as `manual` would strand a board whose own
  wake was still legitimately re-armable, which is the misread #1445 exists to
  end; re-arming a *fresh* bound instead would be the unbounded probe it also
  exists to end.
- **`rearm`** → re-arm the sleep-until-reset `Monitor` for the time remaining to
  `parked_until` (plus the 2-minute buffer), firing `/go-on --generation` with
  the **recorded** `limit_resume_generation`. `/go-on` is the right command for
  **either** owner's park, which is why recovery needs no route field: it
  validates the generation against the same `limit_resume_generation` day mode's
  own wake validates against, then routes on the evidence — with per-PR
  `usage_limit_park` records it runs the phase-aware lane, and with none it falls
  to rank 1 and delegates to `/pause-resume`, forwarding the generation. A
  day-mode park therefore resumes exactly as it always did, and an adopted one
  resumes its pipelines too; mint and publish a fresh one only
  when the recorded value is null. Record the new task ID over the dead one with
  a plain `--set`: the CAS-from-null in §4 guards against a *live* competitor,
  and the ID being replaced here belongs to a Monitor that provably died with
  its session. One line: `Session restarted during usage-window park; resuming automatically at {PARKED_UNTIL}`.
- **`manual`** → re-arm nothing. One line naming why (`weekly cap` or `no usable
  wake bound`) and that `/go-on` is the manual resume.
- **`expired`** → the window has reopened. Resume through `/go-on` rather than
  arming anything.
- **`unreadable`** → re-arm nothing **and dispatch nothing**. Report the read
  failure in one line. This is the fail-closed branch; treating it as `none` is
  how a still-closed window gets a fresh board dispatched into it.
- **`none`** → continue session start unchanged.

**Adoption does not change recovery.** A wake armed by day mode or another
thread is still the one wake, and recovery re-arms exactly one. The per-PR
records from §3 are what tell `/go-on` which pipelines to relaunch, so the right
pipelines resume regardless of which owner armed the wake.

---

## Cross-references

- `/pm` `SKILL.md` 2D.6 (reactive park/wake), 2D.7 (pre-emptive, #1428),
  2D.1(b+) / 2D.5 (recovery) — the machinery this reuses.
- `.claude/reference/pm-day-mode.md` — day-mode mechanism and rationale.
- `.claude/reference/session-state-schema.json` — `.day` park fields, the shared
  slot comment, and `_usage_limit_park_example`.
- `phase-protocols.md`, `monitor-mode.md`, `subagent-orchestration.md` — the
  crash-vs-limit routing that points here.
- `.claude/skills/go-on/SKILL.md` Steps 0.1a / 0.3 / 0.6 — generation gate,
  probe F, and the phase-aware relaunch lane.
- `.claude/reference/usage-limit-signal-audit-2026-07.md` — why no hook receives
  an approaching-limit signal, and what the recorder can and cannot supply.
- Issue #1619 — the pre-emptive leg (out of scope here); issue #1444 —
  cross-thread stop.
