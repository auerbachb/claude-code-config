# Subagent-thread usage-limit park — issues #1618, #1619

**Scope.** The single source of truth for what a thread running Phase A/B/C
subagents does when the account's usage window closes underneath it — or is
about to: how the signal is recognised, how the board is parked, how the wake is
armed, how the parked pipelines resume, and how an interrupted session re-arms.
Rule files and skills point here; the procedure is not restated anywhere else.

**Two triggers, one procedure.** §1–§6 are the **reactive** leg (#1618): a kill
has already landed. §7 is the **pre-emptive** leg (#1619): the monitor loop reads
the usage horizon each cycle and parks while there is still runway, exactly as
`/pm` day mode's 2D.7 does. §7 adds a trigger, a cause value, and a wake shape —
it reuses §2's claim, §3's records, §4's wake, §5's resume, and §6's recovery
rather than restating any of them. §8 records which loop may park which work.

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
#   PARK_CAUSE  the cause this leg claims: `reactive` (§1) or `preemptive` (§7).
#               Defaults to `reactive`, so the reactive leg passes nothing.
#   CLAIM_FIRES the probe bound written with the claim: `null` whenever a reset
#               time is known — which is always true reactively — and §7's
#               positive fire count when it is not. Same three-valued field
#               every recovery reader already branches on (#1445).
# Outputs: PARK_CLAIM=won|adopted|error, NEW_HITS.
PARK_CAUSE="${PARK_CAUSE:-reactive}"
CLAIM_FIRES="${CLAIM_FIRES:-null}"
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
    --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"$PARK_CAUSE\"" --expect null \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=\"$PARKED_UNTIL\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"$LIMIT_KIND\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=$CLAIM_FIRES" \
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
write_pr_park() {
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].prs[\"$PR_NUM\"].usage_limit_park=$PARK_PR_JSON" \
    --set ".repos[\"$REPO_KEY\"].prs[\"$PR_NUM\"].handoff_reason=\"usage_limit_park\"" \
    >/dev/null 2>&1
}
write_pr_park || PR_PARK_RC=$?
# Exit 6 is a lock timeout — transient and documented as retryable
# (`handoff-files.md`) — and it leaves state UNCHANGED, so the record is simply
# absent: Probe F and /pause-resume Step 5 scan for exactly this field and would
# both miss the PR. Retry ONCE, as the prose below requires; a second failure is
# a lost pipeline to be named in the report, not a warning to be logged.
if [ "$PR_PARK_RC" -eq 6 ]; then
  PR_PARK_RC=0
  write_pr_park || PR_PARK_RC=$?
fi
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
#   PARK_RESET_KNOWN  true when RESET_EPOCH came from a real reset time.
#                     Defaults to true: the reactive leg always has one (§1
#                     falls back to the 60-minute rolling window), and only §7's
#                     horizon park can reach here with no reset time at all.
#   PROBE_CADENCE_MIN / PROBE_MAX_FIRES  §7's probe knobs; never read when the
#                     reset is known, so the reactive leg passes neither.
# Outputs: WAKE=armed|probe|capped|weekly, WAKE_SLEEP, WAKE_GENERATION,
#          WAKE_COMMAND.
MAX_LIMIT_HITS=3
PARK_RESET_KNOWN="${PARK_RESET_KNOWN:-true}"
WAKE_SLEEP=""; WAKE_GENERATION=""; WAKE_COMMAND=""
if [ "$LIMIT_KIND" = weekly ]; then
  WAKE=weekly
  echo "stopped — weekly cap reached; pipelines parked. Resume manually with /go-on when the window reopens at $PARKED_UNTIL"
elif [ "$NEW_HITS" -ge "$MAX_LIMIT_HITS" ]; then
  WAKE=capped
  echo "Parked (usage limit) — $NEW_HITS consecutive limit hits on resume; staying parked to avoid a hot loop. Resume manually with /go-on."
elif [ "$PARK_RESET_KNOWN" != true ]; then
  # No reset time means there is nothing to sleep UNTIL: arm 2D.7's bounded probe
  # rather than a one-shot. WAKE_SLEEP is a cadence here, not a deadline, and the
  # bound lives in `limit_probe_fires_remaining`, never in the loop — so a session
  # restart re-arms with the fires that are LEFT, not a fresh count (#1445).
  WAKE=probe
  WAKE_SLEEP=$(( PROBE_CADENCE_MIN * 60 ))
  WAKE_GENERATION="probe-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  WAKE_COMMAND="/pm day --probe-wake --day-generation $WAKE_GENERATION"
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
— and publish its identity immediately. Its command is `/go-on --generation`, not
a bare `/pause-resume`, which re-arms live runtime IDs and would leave every
parked pipeline stopped. `/go-on` classifies the stoppage and relaunches each dead
Phase A/B/C pipeline at its recorded phase without a day-mode turn to route
through. The probe branch below reaches that same phase-aware relaunch by the
other road — `/pause-resume --generation`, whose Step 5 replays the per-PR records
§3 wrote — so the choice here is which entry point fits an `armed` wake, not a
claim that only one command can restart a parked pipeline. It remains the same
wake *class* in the same registry, so
`/pause` Step 2 item 4 and `/pause-resume` Step 5 tear it down unchanged.

On `WAKE=probe` (§7 only, when no reset time is known), arm **one** persistent
`Monitor` running 2D.7's repeating shape instead — the same loop **without** the
`break`, so it fires at the cadence until the bound is spent — and publish its
identity through the very same block below. Still not a second wake class: same
registry, same two identity fields, same `/pause` teardown, same `/pause-resume`
disarm, same generation check.

**The probe branch does not print `/go-on`, and that is deliberate.** Its command
is `/pm day --probe-wake --day-generation <id>`, because a probe fire has to
re-read the horizon and spend one of a *persisted* count before anything resumes,
and `/go-on` has no handler for either. Pointing the probe at `/go-on` would arm
an unbounded wake that resumes on its first fire whatever the horizon then says —
the runaway the bound exists to prevent.

**Where a probe fire goes, end to end.** `/pm` routes a `--probe-wake` turn
straight to 2D.7 Step 5, which validates the generation against the same
`limit_resume_generation` published below, re-reads the horizon, and spends one
fire. Only `clear` resumes, and it resumes by invoking `/pause-resume
--generation <id>` — whose Step 5 relaunches exactly the per-PR records §3 wrote,
claiming each PR as it goes. So each branch has exactly one command and they meet
at one relaunch: `/go-on --generation` for `armed`, `/pm day --probe-wake` →
`/pause-resume --generation` for `probe`. Those are §5's two entry points, not a
third route, and nothing in the chain is new — this branch adds a `Monitor`
command string and nothing else.

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
  `--cas '.repos["<key>"].day.limit_cause=null' --expect '"<PARK_CAUSE>"'` composed
  with `--set` writes nulling `parked_until`, `limit_kind`, and
  `limit_probe_fires_remaining`. Clearing `parked_until` alone is not enough:
  `limit_cause` is the compare-and-set field every parker claims through, so a
  cause left standing means no future park — this thread's, day mode's, or a
  sibling's — can ever win the compare again, and the board is permanently
  unparkable while reading as unparked. Gating on the cause **this leg claimed**
  — `"reactive"` from §1, `"preemptive"` from §7 — is what keeps the release from
  clearing a park that landed meanwhile: exit 7 means someone else owns the
  record now, so clear nothing and stand down. Name the unrecorded task
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
above; `/pause-resume --generation` — the wake day mode arms, and the one §7's
probe fire ends at — reaches it
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

## 7. Pre-emptive — park at the usage horizon (#1619)

**Trigger.** This thread's own horizon read, once per monitor cycle — not a
kill. §1–§6 wait for the wall; §7 sees it coming, so the board winds down with a
landing window instead of dying mid-review-loop with fixes half-pushed and
replies unposted. `monitor-mode.md`'s per-cycle checklist and `/subagent` Step 8
are the two loops that run it.

**Same machinery, three deltas.** The claim is §2's, the per-PR records are
§3's, the wake is §4's, the resume is §5's, and the recovery is §6's. What
changes is only: the **cause** written into the shared slot (`preemptive`, not
`reactive`), the **landing window** the shutdown gets (calls still succeed, so
near-done work can land), and the **wake shape** when no reset time exists (a
bounded probe rather than a sleep-until-reset one-shot). No second park record,
no second wake class, no second resume route — the same sentence 2D.7 binds
itself with, for the same reason.

**Quota authority is unchanged.** The only number that reaches this section is
the one the **harness printed** into context — `<total_tokens>N tokens
left</total_tokens>`, refreshed after every tool result. It is handed to
`usage-horizon.sh`, which compares and never derives. Nothing here counts
tokens, reads a transcript, or estimates spend, so `safety.md`'s horizon
carve-out (#1427) covers this reader exactly as written and needs no amendment.
Never substitute a remembered figure for a counter that is not in context: an
absent reading is `unknown`, and `unknown` never parks.

### 7.1 Read the horizon, every cycle

Observe the harness counter, then branch on `--check`. This is `/pm` 2D.7's D2
gate with the same inputs, the same clamp, and the same four outcomes — the two
copies are held to identical verdicts by a parity test, so a change to one that
the other does not make is a test failure rather than a silent divergence.

<!-- test-anchor: subagent-limit-horizon-gate -->

```bash
# USAGE_HORIZON_SH: resolved per the RESOLVE contract (Step 0's candidate order).
# HORIZON_REMAINING / HORIZON_LIMIT: the numbers the HARNESS printed this turn.
# Leave both empty when the counter is not in context — never substitute a
# remembered figure. An absent reading is never `clear`, but it is not inert
# either: with nothing to observe, the gate falls through to `--check`, which
# answers `unknown` unless THIS session already recorded a reading inside its
# TTL. A live same-session `critical` does still park, and should — the counter
# only falls within a session, so the reading a fresh figure would have
# corrected is stale only in the safe direction.
HORIZON_STATUS=unknown
HORIZON_OBSERVE_RC=0
if [ -n "${USAGE_HORIZON_SH:-}" ] && [ -n "${HORIZON_REMAINING:-}" ]; then
  if [ -n "${HORIZON_LIMIT:-}" ]; then
    "$USAGE_HORIZON_SH" --observe "$HORIZON_REMAINING" --limit "$HORIZON_LIMIT" \
      >/dev/null 2>&1 || HORIZON_OBSERVE_RC=$?
  else
    "$USAGE_HORIZON_SH" --observe "$HORIZON_REMAINING" >/dev/null 2>&1 || HORIZON_OBSERVE_RC=$?
  fi
fi
if [ -n "${USAGE_HORIZON_SH:-}" ] && [ "$HORIZON_OBSERVE_RC" -eq 0 ]; then
  HORIZON_OUT=$("$USAGE_HORIZON_SH" --check 2>/dev/null) || true
  _HS=$(printf '%s\n' "$HORIZON_OUT" | sed -n 's/^STATUS=//p' | head -1)
  # Match the three known verdicts EXPLICITLY. A `!= critical` test would read a
  # missing script, a garbage line, and a displaced session as permission to launch.
  case "$_HS" in clear|approaching|critical) HORIZON_STATUS="$_HS" ;; *) HORIZON_STATUS=unknown ;; esac
  HORIZON_REASON=$(printf '%s\n' "$HORIZON_OUT" | sed -n 's/^REASON=//p' | head -1)
fi
case "$HORIZON_STATUS" in
  clear)       HORIZON_REFILL_OK=true;  HORIZON_PARK=false; HORIZON_IDLE_REASON="" ;;
  approaching) HORIZON_REFILL_OK=false; HORIZON_PARK=false; HORIZON_IDLE_REASON="paused (horizon approaching)" ;;
  critical)    HORIZON_REFILL_OK=false; HORIZON_PARK=true;  HORIZON_IDLE_REASON="paused (horizon critical)" ;;
  *)           HORIZON_REFILL_OK=false; HORIZON_PARK=false; HORIZON_IDLE_REASON="paused (horizon unknown)" ;;
esac
printf 'HORIZON_STATUS=%s\nHORIZON_REFILL_OK=%s\nHORIZON_PARK=%s\nHORIZON_IDLE_REASON=%s\nHORIZON_REASON=%s\n' \
  "$HORIZON_STATUS" "$HORIZON_REFILL_OK" "$HORIZON_PARK" "$HORIZON_IDLE_REASON" "${HORIZON_REASON:-}"
```

A non-zero `HORIZON_OBSERVE_RC` is a real write, usage, or lock failure — never a
verdict, since `--observe` exits `0` whatever it reads — so the gate skips
`--check` and holds `unknown`. That clamp costs at most a cycle of refill and can
never park, which is the right direction: the counter only falls during a
session, so a stale reading is optimistic.

### 7.2 `approaching` — launch nothing new; park nothing

`HORIZON_REFILL_OK=false` with `HORIZON_PARK=false`. For this cycle:

- **Running pipelines are untouched.** They keep going, their phase transitions
  still execute, and their subagents are not stopped. Stopping healthy work on a
  posture is the over-reaction the landing window exists to avoid.
- **No new launches.** The monitor loop's refill step (`monitor-mode.md` item 4,
  `/subagent` Step 8 step 4) starts nothing: no queued chain head, no backlog
  pick, no replacement pipeline for a slot that just freed. This is the same
  stop `refill.paused` produces, reached from a different reason, and it binds
  the queue head exactly as it binds the backlog.
- **A→B and B→C transitions still run.** A successor of a pipeline already in
  flight is finishing work, not starting it; barring it would strand a pushed
  branch with nobody to review it. Only a **new pipeline** is barred.
- **Report it on the idle line** as `paused (horizon approaching)`, one
  always-emit line naming the runway.

Nothing is written to the park record, and no wake is armed. `approaching` is
reversible: the next cycle that reads `clear` refills normally.

### 7.3 `unknown` — a posture, never an event

Identical to `approaching` in what it stops, and different in what it means: the
horizon slot is machine-wide, so a session displaced by a sibling reads `unknown`
routinely rather than exceptionally (`usage-horizon.sh --help` §CONCURRENT
SESSIONS). It stops new launches, changes no state, arms nothing, parks nothing,
and reports `paused (horizon unknown)`. The one thing it must never do is read as
`clear` — which is why 7.1 matches the three verdicts explicitly instead of
testing for `critical`.

### 7.4 `critical` — park, with a landing window

Resolve the knobs, derive the deadline, then run §2 → shutdown → §3 → §4 with
the pre-emptive parameters. The knobs are 2D.7's, with 2D.7's validation and
2D.7's reasons for rejecting zero on the two probe knobs:

| Value | Default | Env | Accepted |
|-------|---------|-----|----------|
| Landing window for the park | `2` minutes | `CLAUDE_HORIZON_PARK_WINDOW_MINUTES` | `^[0-9]{1,6}$` — **`0` is legal** and selects §1's reactive parity |
| Probe cadence | `30` minutes | `CLAUDE_HORIZON_PROBE_CADENCE_MINUTES` | `^[0-9]{1,6}$` **and `> 0`** |
| Probe fire bound | `12` fires | `CLAUDE_HORIZON_PROBE_MAX_FIRES` | `^[0-9]{1,6}$` **and `> 0`** |

<!-- test-anchor: subagent-limit-preemptive-window -->

```bash
# Outputs: PARK_CAUSE, LIMIT_KIND, PARK_WINDOW_MIN, PROBE_CADENCE_MIN,
#          PROBE_MAX_FIRES, RESET_EPOCH, PARKED_UNTIL, PARK_RESET_KNOWN,
#          CLAIM_FIRES — every input §2 and §4 need, and nothing else.
# The table above documents the knobs; it cannot enforce them, so they resolve
# HERE. A knob that fell through to 0 would make PARKED_UNTIL equal now, and
# every reader treats a non-future parked_until as "no park" — the board would
# stop while its own durable record said it had not.
# Every accepted knob is normalised through `10#` (#1619 review). `^[0-9]+$`
# admits a leading zero and `[ 08 -gt 0 ]` accepts it, but `$(( 08 * … ))` below is
# an OCTAL context and dies with "value too great for base" — leaving RESET_EPOCH
# empty and PARKED_UNTIL garbage, the exact silent half-park these knobs guard.
# `08` also reaches session-state.sh as a JSON number, which jq rejects.
# The digit bound is the same guard aimed at magnitude (#1619 review). A bare
# `^[0-9]+$` accepts a 20-digit knob that `10#` then WRAPS SILENTLY — rc 0, no
# error: `$(( 10#99999999999999999999 ))` is 7766279631452241919, and one more
# `* 60` lands on 0. That is a non-future PARKED_UNTIL, which every reader in
# this file treats as "the park resolved or never existed" — the same silent
# half-park by a different road. Six digits is ~1.9 years of minutes.
PARK_WINDOW_MIN=2; PROBE_CADENCE_MIN=30; PROBE_MAX_FIRES=12
if [ -n "${CLAUDE_HORIZON_PARK_WINDOW_MINUTES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PARK_WINDOW_MINUTES" =~ ^[0-9]{1,6}$ ]]; then
    PARK_WINDOW_MIN=$(( 10#$CLAUDE_HORIZON_PARK_WINDOW_MINUTES ))   # 0 is legal — reactive parity
  else
    echo "horizon: rejected CLAUDE_HORIZON_PARK_WINDOW_MINUTES='$CLAUDE_HORIZON_PARK_WINDOW_MINUTES' — using 2" >&2
  fi
fi
if [ -n "${CLAUDE_HORIZON_PROBE_CADENCE_MINUTES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES" =~ ^[0-9]{1,6}$ ]] && [ "$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES" -gt 0 ]; then
    PROBE_CADENCE_MIN=$(( 10#$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES ))
  else
    echo "horizon: rejected CLAUDE_HORIZON_PROBE_CADENCE_MINUTES='$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES' — using 30" >&2
  fi
fi
if [ -n "${CLAUDE_HORIZON_PROBE_MAX_FIRES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PROBE_MAX_FIRES" =~ ^[0-9]{1,6}$ ]] && [ "$CLAUDE_HORIZON_PROBE_MAX_FIRES" -gt 0 ]; then
    PROBE_MAX_FIRES=$(( 10#$CLAUDE_HORIZON_PROBE_MAX_FIRES ))
  else
    echo "horizon: rejected CLAUDE_HORIZON_PROBE_MAX_FIRES='$CLAUDE_HORIZON_PROBE_MAX_FIRES' — using 12" >&2
  fi
fi
PARK_CAUSE=preemptive
# A pre-emptive park is ALWAYS rolling_window: the horizon verdict measures the
# rolling window's runway and classifies no cap kind. Weekly caps stay the
# reactive leg's business and stay manual-resume (§4).
LIMIT_KIND=rolling_window
NOW_EPOCH=$(date -u +%s)
# HORIZON_RESET_EPOCH is set ONLY from a structured reset field on a vendor
# notice already in hand (§1's rule, unchanged) — never parsed out of prose and
# never derived locally. Absent one, the probe bound's outer edge is the
# conservative deadline, and PARK_RESET_KNOWN=false selects the probe wake.
if [[ "${HORIZON_RESET_EPOCH:-}" =~ ^[0-9]+$ ]] && (( HORIZON_RESET_EPOCH > NOW_EPOCH )); then
  RESET_EPOCH="$HORIZON_RESET_EPOCH"; PARK_RESET_KNOWN=true; CLAIM_FIRES=null
else
  RESET_EPOCH=$(( NOW_EPOCH + PROBE_CADENCE_MIN * PROBE_MAX_FIRES * 60 ))
  PARK_RESET_KNOWN=false; CLAIM_FIRES="$PROBE_MAX_FIRES"
fi
PARKED_UNTIL=$(date -u -d "@$RESET_EPOCH" +%FT%TZ 2>/dev/null || date -u -r "$RESET_EPOCH" +%FT%TZ)
printf 'PARK_CAUSE=%s\nLIMIT_KIND=%s\nPARK_WINDOW_MIN=%s\nPROBE_CADENCE_MIN=%s\nPROBE_MAX_FIRES=%s\nPARKED_UNTIL=%s\nPARK_RESET_KNOWN=%s\nCLAIM_FIRES=%s\n' \
  "$PARK_CAUSE" "$LIMIT_KIND" "$PARK_WINDOW_MIN" "$PROBE_CADENCE_MIN" "$PROBE_MAX_FIRES" \
  "$PARKED_UNTIL" "$PARK_RESET_KNOWN" "$CLAIM_FIRES"
```

**Why no `-1` sentinel here, when 2D.7 writes one.** 2D.7 claims in Step 1 and
finishes the record in Step 3, with the whole shutdown in between, so it stamps
`-1` to stop a restart inside that gap from reading a null bound as "reset time
known". §2's claim has no such gap: the cause, the deadline, the kind, the bound,
and the thrash count ride **one** atomic write (#1445), so the real bound is
written from the first instant and a restart inside the landing window recovers
correctly through §6's `rearm_probe` branch. `-1` is still honoured as a
**reader** — §6 already treats it exactly as a spent bound.

Then, in order:

1. **Claim (§2), before stopping anything.** Pass `PARK_CAUSE=preemptive` and
   the `CLAIM_FIRES` above; everything else is §2 unchanged, including its
   fail-closed handling of an unreadable or malformed `consecutive_limit_hits`
   and its `won` / `adopted` / `error` verdicts. `adopted` means day mode's
   2D.6/2D.7 or a sibling thread already owns this repo's park: record the
   pipelines (step 3) and arm nothing — §8.
2. **Wind down with a landing window.** `execution-pause.sh --activate --command
   pause --window-minutes "$PARK_WINDOW_MIN"`, then `/pause` Steps 2–7 with
   `--window "${PARK_WINDOW_MIN}m"`, **skipping only Step 1's `.refill.paused`
   write** — §2's carve-out, for §2's reason. The non-zero window is the whole
   point of firing before the wall: calls still succeed, so a PR one merge away
   can land. It is a budget, not a promise — `/pause`'s own `T_END` reclassifies
   anything that has not landed as `park`.
3. **Record each surviving pipeline (§3),** with the phase it holds **after** the
   landing window, not before it: a pipeline that merged during the window has
   nothing to resume, and one whose Phase A pushed inside it resumes at Phase B.
   A `PR_PARK=<N>:error` line is still a lost pipeline, named in the report.
4. **Arm the wake (§4),** passing `PARK_RESET_KNOWN` and the two probe knobs.
   A known reset arms the sleep-until-reset one-shot; an unknown one arms the
   bounded probe. The thrash guard, the weekly branch, and the identity publish
   are §4's, unchanged. Skip this step entirely on `adopted`.

### 7.5 Chat surface

Two always-emit lines on park, one on resume; nothing else:

```text
parked pre-emptively (usage horizon) — landed PR #1421, checkpointed PR #1430 (Phase B), 2 queued
window reset unknown — probing every 30m, up to 12 checks (through 05:12 AM ET)
```

With a known reset the second line is §4's shape instead (`resuming
automatically at {PARKED_UNTIL}`). On an adopted park, say nothing beyond the
first line — the owner's wake already announced itself.

### 7.6 Recovery and teardown parity

Nothing new. §6 already branches on `limit_cause` and the three-valued
`limit_probe_fires_remaining`: a pre-emptive park with fires left re-arms the
probe **with that count** (`rearm_probe`), a known-reset park re-arms the
one-shot (`rearm`), and `0`, `-1`, a weekly kind, or an unreadable value all take
the manual branch. `/pause` stops the probe Monitor and `/pause-resume` disarms
it through the same two identity fields, because it is the same wake class.

---

## 8. Which loop may park which work (decision, joint with #1444)

**One repo, one park record, claimed by compare-and-set on `limit_cause`.** That
field is null until exactly one path claims it, and every parker — §1's reactive
leg, §7's pre-emptive leg, `/pm` 2D.6, `/pm` 2D.7, a sibling thread on the same
repo — claims through it. A `/subagent` thread and a day-mode loop can therefore
race freely: one wins, the other's compare returns exit 7 and it **adopts**,
recording its own pipelines (§3) and arming no second `Monitor`. Double-parking
is not prevented by a rule that loops are asked to obey; it is unrepresentable.

**Who may claim, and who may only adopt:**

| Loop | May claim a park | Why |
|------|------------------|-----|
| `/pm day` (2D.6, 2D.7) | **yes** | Owns the repo's between-turn dispatch (`pm-monitoring-decision.md`) |
| A thread running Phase A/B/C subagents (`/subagent`, `monitor-mode.md`) | **yes** | Owns the pipelines it launched; nothing else can record or resume them |
| `/pr-monitor-and-manage`, `/babysit-pr` (#1444) | **no — honour and adopt only** | They dispatch recovery on PRs other loops own; a third claimant adds races without adding reachable work |

**The principle is launch ownership, not loop seniority.** A loop may park the
work it launched, because it is the only loop that can record that work's phase
and the only one whose resume can put it back. A loop that merely watches PRs
someone else launched has nothing of its own to record, so on `critical` it stops
dispatching, adopts an existing park if one is there, and otherwise reports and
stands down — which is what #1444 has to implement, and all it has to implement.

**The two claim orders interleave to one record and one wake.** `/pm` 2D.7
claims `parked_until` first (Step 1) and takes `limit_cause` when it finishes the
record (Step 3); §2 takes `limit_cause` and the whole record in one write. Both
interleavings are safe, and neither needs the other to change:

- **Subagent first.** Day mode's Step 1 compare on `parked_until` finds a value
  and returns exit 7 — `PARK_CLAIM=lost`, which ends its tick before any
  shutdown. One record, one wake, no second shutdown.
- **Day mode first.** Its Step 1 owns `parked_until` with `limit_cause` still
  null, so §2's compare wins and the record becomes the subagent's — including
  the per-PR pipeline records only it can write. Day mode's Step 3 compare then
  returns exit 7, which is its documented `superseded` branch: write nothing, arm
  nothing, say nothing. Again one record and one wake, and the winner is the
  owner that has pipelines to resume.

Neither path can reach §4 or 2D.7 Step 4 without having won its own compare, so
"two wakes armed" is not a race that has to be won — it has no interleaving.

**`approaching` and `unknown` need no ownership rule at all.** They start nothing
and write nothing, so every loop may honour them independently and none of them
can collide. Only `critical` touches durable state, and only `critical` is
arbitrated by the compare-and-set above.

**Scope note.** §8 is the shared decision record both issues cite. §8.1 below
holds issue #1444's half of it: the contract `/pr-monitor-and-manage` and
`/babysit-pr` follow to honour a horizon verdict without ever claiming a park.

### 8.1 Honour-and-adopt — the watch-only loop contract (#1444)

**Who this is.** A loop that dispatches recovery on PRs it did not launch:
`/pr-monitor-and-manage` (rediscovers your open PRs each tick) and
`/babysit-pr` (watches one PR). Neither holds an issue claim, a queue, or a
phase record, so neither has anything of its own to record in a park — §8's
launch-ownership principle, applied.

**The consult is §7.1's, unchanged.** Run the §7.1 gate block, resolved through
the caller's own candidate order; do not re-derive the branch and do not keep a
second copy of it. It yields `HORIZON_STATUS` and, with it, `HORIZON_PARK` —
which a watch-only loop reads as *a park is warranted*, never as *I may claim
one*. `USAGE_HORIZON_SH` unresolved holds `unknown`, which never reads as
`clear`.

**Start versus finish, the same split §7.2 makes.** `approaching` and `unknown`
stop a loop from *starting* new background work — a fresh `phase-a-fixer`, a new
`/fixpr` dispatch, and the shared `pr-preflight.sh` step, which flips a draft ready
and engages four reviewers and so starts a round of bot reviews and CI as surely as a
dispatch does — and leave *finishing* work alone. A caller therefore has to read this
verdict **before** its pre-flight step, not after it, or the runway is spent before the
gate is consulted. `/wrap` on a PR that is
already merge-ready, and a rebase of a PR already in the fleet, are finishing:
barring them would strand a PR one merge from done for the length of a park,
which is the outcome the landing window in §7.4 exists to prevent. Only
`critical` stops both.

| Verdict | Start new dispatch | Finish in-flight work | Own loop | Writes |
|---------|--------------------|-----------------------|----------|--------|
| `clear` | yes | yes | continues | none |
| `approaching` | **no** | yes | continues, names the runway | none |
| `unknown` | **no** | yes | continues, says the verdict was unreadable | **none, ever** |
| `critical` | no | no | **stands down** | its own namespace only |

**`critical` — stand down, adopt, never claim.** The loop stops dispatching and
stands its own poll down in its own namespace: `/pr-monitor-and-manage` takes
its existing Pause route (`.pmm.*`, cause `usage_horizon`), `/babysit-pr` widens
its own cadence (`.prs["<N>"].babysit.*`). It then *reads* the shared repo slot
to say whether a park is already open, and reports which it saw. It never runs
`--cas` on `limit_cause`, never `--set` on `.repos["<key>"].day.*`, and never
arms a wake — the park's owner already armed one, and where no park exists the
absence is a fact to report, not a slot to fill.

**Why read-only adoption is enough, and why a third claimant would not be.** A
watch-only loop's entire contribution to a park would be a record with no
pipelines in it and a wake that resumes a poll the user can restart with one
command. Against that, a third claimant on one repo's slot adds interleavings to
a compare-and-set that §8 keeps small on purpose. The precedent is the same one
`bgwork-ceiling.sh` and `credit-budget.sh` set: one machine-wide signal, many
independent readers, each standing down its own work.

<!-- test-anchor: watchonly-horizon-posture -->

```bash
# Inputs:  HORIZON_STATUS (from §7.1's gate block), SESSION_STATE_SH, REPO_KEY.
# Outputs: WATCH_LAUNCH_OK   — may this loop START new background work?
#          WATCH_FINISH_OK   — may it finish work already in flight (/wrap, rebase)?
#          WATCH_STAND_DOWN  — must it stand its own poll down this tick?
#          WATCH_PARK_SEEN   — true | false | unreadable (READ-ONLY probe)
#          WATCH_IDLE_REASON — the heartbeat phrase, empty only on `clear`.
# This block writes NOTHING. A watch-only loop honours a park; it never claims
# one, so there is no --cas here and no --set on .repos["<key>"].day.* anywhere
# in this contract.
case "${HORIZON_STATUS:-unknown}" in
  clear)       WATCH_LAUNCH_OK=true;  WATCH_FINISH_OK=true;  WATCH_STAND_DOWN=false; WATCH_IDLE_REASON="" ;;
  approaching) WATCH_LAUNCH_OK=false; WATCH_FINISH_OK=true;  WATCH_STAND_DOWN=false; WATCH_IDLE_REASON="paused (horizon approaching)" ;;
  critical)    WATCH_LAUNCH_OK=false; WATCH_FINISH_OK=false; WATCH_STAND_DOWN=true;  WATCH_IDLE_REASON="paused (horizon critical)" ;;
  # Every other value — including a verdict this contract does not know — is
  # `unknown`, and `unknown` is a posture: it starts nothing, parks nothing, and
  # is never read as `clear` (§7.3).
  *)           WATCH_LAUNCH_OK=false; WATCH_FINISH_OK=true;  WATCH_STAND_DOWN=false; WATCH_IDLE_REASON="paused (horizon unknown)" ;;
esac
# The adopt probe runs only where it can change what the loop SAYS — on a
# stand-down. Its failure is reported, never converted into a verdict: a park
# that cannot be read is not a park that is absent.
WATCH_PARK_SEEN=false
if [ "$WATCH_STAND_DOWN" = true ]; then
  WATCH_PARK_SEEN=unreadable
  if [ -n "${SESSION_STATE_SH:-}" ] && [ -n "${REPO_KEY:-}" ]; then
    _PARK_RC=0
    # ONE `--get-json` of the whole `.day` object, not a field at a time: 2D.7
    # claims `parked_until` in its Step 1 and takes `limit_cause` only when it
    # finishes the record (§8), so a probe that read `limit_cause` alone would
    # report "no park open" during the window where a park is half-assembled —
    # and two separate reads could straddle that window and disagree with each
    # other. `--get-json` also keeps an absent slot distinguishable from the
    # JSON string "null" that a raw `--get` flattens them both into.
    _PARK_DAY=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) || _PARK_RC=$?
    # rc 3 is "no state file has ever been written" — a real, readable absence.
    # Any other non-zero is unreadable state and stays unreadable.
    if [ "$_PARK_RC" -eq 3 ]; then
      WATCH_PARK_SEEN=false
    elif [ "$_PARK_RC" -eq 0 ]; then
      # Either field non-null is an open park. jq's own failure (malformed
      # payload) is unreadable, never "absent" — same rule as a failed read.
      if printf '%s' "${_PARK_DAY:-null}" | jq -e '(.limit_cause // null) != null or (.parked_until // null) != null' >/dev/null 2>&1; then
        WATCH_PARK_SEEN=true
      elif printf '%s' "${_PARK_DAY:-null}" | jq -e 'type == "object" or type == "null"' >/dev/null 2>&1; then
        WATCH_PARK_SEEN=false
      fi
    fi
  fi
fi
printf 'WATCH_LAUNCH_OK=%s\nWATCH_FINISH_OK=%s\nWATCH_STAND_DOWN=%s\nWATCH_PARK_SEEN=%s\nWATCH_IDLE_REASON=%s\n' \
  "$WATCH_LAUNCH_OK" "$WATCH_FINISH_OK" "$WATCH_STAND_DOWN" "$WATCH_PARK_SEEN" "$WATCH_IDLE_REASON"
```

**Chat surface.** One always-emit line on stand-down, folded into the loop's own
heartbeat rather than added beside it:

```text
[Sat Sep 5 04:31 AM ET] PMM standing down — usage horizon critical, adopting the park already open for auerbachb/claude-code-config; resume with /pr-monitor-and-manage-wake
```

With `WATCH_PARK_SEEN=false`, say `no park open — nothing dispatched` in place
of the adopting clause; with `unreadable`, say the park slot could not be read.
On `approaching` / `unknown` the loop's existing heartbeat carries
`WATCH_IDLE_REASON` and nothing else changes.

**Resuming.** A stood-down watch-only loop resumes on its own route — for
`/pr-monitor-and-manage`, `/pr-monitor-and-manage-wake`, which re-runs this
consult before it resumes and stays parked while the verdict is still
`critical`. Nothing here is resumed by the park owner's wake: the owner resumes
the pipelines it recorded, and it recorded none of these.

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
- `.claude/scripts/usage-horizon.sh --help` — the verdict contract §7.1 consumes.
- `.claude/skills/pr-monitor-and-manage/SKILL.md` Step 3.7 / Step 5 / Step 7,
  `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` Step 3.5, and
  `.claude/skills/babysit-pr/SKILL.md` T1a / T1b / T4 / T5 — the four call sites of
  §8.1's watch-only contract (#1444).
