---
name: go-on
description: Use when stopped work should be picked back up, whatever stopped it — `/pause`, `/end`, a token-exhaustion handoff, an account usage-limit park, a session that died (crash, compaction, sign-out), or a stalled review/merge workflow. Universal resume — classifies the stoppage from the evidence. Invoke as `/go-on [--resume-refill] [--again] [--generation <id>]`.
triggers:
  - go-on
  - resume
  - pick up where we left off
  - continue the interrupted work
  - what was I doing
argument-hint: "[--resume-refill] [--again] [--generation <id>] (refill stays paused without --resume-refill)"
---

Resume the work, whatever stopped it. Step 0 classifies the stoppage from recorded evidence and routes; Steps 0b–10 are the interrupted-review-workflow lane it routes to.

## Portable helper resolution (workflow lane)

Resolve every lifecycle helper **before entering Steps 0b–10**, not before Step 0: classification needs only the stop-state helpers resolved in 0.2, and a resume that just routes to `/pause-resume` must not be blocked by a missing merge-gate helper it will never call. Inside the workflow lane a missing helper blocks rather than guessing which completed state is safe.

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
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
DIFF_SURVIVAL_SH=$(resolve_script diff-survival-check.sh || true)
REVIEWER_OF_SH=$(resolve_script reviewer-of.sh || true)
PR_STATE_SH=$(resolve_script pr-state.sh || true)
REPLY_THREAD_SH=$(resolve_script reply-thread.sh || true)
RESOLVE_REVIEW_THREADS_SH=$(resolve_script resolve-review-threads.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh || true)
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh || true)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — resume authorship gate unavailable" >&2; exit 1; }
[[ -n "$DIFF_SURVIVAL_SH" ]] || { echo "ERROR: diff-survival-check.sh not found (checked all three paths) — rebase survival gate unavailable" >&2; exit 1; }
[[ -n "$REVIEWER_OF_SH" ]] || { echo "ERROR: reviewer-of.sh not found (checked all three paths) — reviewer routing unavailable" >&2; exit 1; }
[[ -n "$PR_STATE_SH" ]] || { echo "ERROR: pr-state.sh not found (checked all three paths) — PR state unavailable" >&2; exit 1; }
[[ -n "$REPLY_THREAD_SH" ]] || { echo "ERROR: reply-thread.sh not found (checked all three paths) — review replies unavailable" >&2; exit 1; }
[[ -n "$RESOLVE_REVIEW_THREADS_SH" ]] || { echo "ERROR: resolve-review-threads.sh not found (checked all three paths) — thread resolution unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge gate unavailable" >&2; exit 1; }
[[ -n "$CLEAN_BEHIND_SH" ]] || { echo "ERROR: clean-behind-check.sh not found (checked all three paths) — clean-BEHIND verification unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
```

Walk through the full review lifecycle checklist in order. At each step, check if it's already been completed. Stop at the first incomplete step and execute it, then continue to the next step. Keep going until the workflow is complete or a blocking condition is hit.

**Output a status line at each step** so the user can follow along:
- `[DONE]` — step already completed, moving on
- `[ACTION]` — step incomplete, executing now
- `[BLOCKED]` — step cannot proceed, reporting why
- `[SKIP]` — step not applicable

---

## Step 0: Classify the stoppage (universal resume)

Every stoppage leaves evidence. Read it, decide which class this is, and continue from the right place — the user never names the stoppage class. `/pause-resume` and `/end-resume` keep working and still own their restores; this step **routes into them** rather than reimplementing them (the "delegation, not reimplementation" rule in `/pause-resume` §Safety).

Evidence sources, the precedence table, the newest-wins tie-break, and the degradation contract: `.claude/reference/universal-resume.md`.

### 0.1 Parse arguments

- `--resume-refill` — forwarded **verbatim** to the delegated resume command. `/go-on` never writes `refill.paused` itself. Without the flag the refill pause stands on every lane and is reported, and on a lane with no planned-stop record the flag is reported as having had no effect (naming the command that clears it) — never acted on directly.
- `--again` — ignore the resume receipt in 0.5 and re-evaluate from scratch.
- `--generation <id>` — **internal**: only the usage-limit wake armed by `.claude/reference/subagent-thread-limit-park.md` §4 passes it. It asserts "I am the wake this repo's park record armed", and 0.2a rejects it when that is no longer true.

### 0.2 Resolve the stop-state helpers

These read cross-session stop records, so they resolve from installed locations **only** — no current-checkout fallback, matching `/pause-resume` and `/end-resume` Step 0. `/go-on` may be invoked from an unrelated or untrusted checkout, whose executable bit is not a trust signal.

```bash
resolve_installed() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_installed session-state.sh) || SESSION_STATE_SH=""
EXECUTION_PAUSE_SH=$(resolve_installed execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_installed background-task-registry.sh) || TASK_REGISTRY_SH=""
HANDOFF_STATE_SH=$(resolve_installed handoff-state.sh) || HANDOFF_STATE_SH=""

SESSION_ID="${CLAUDE_SESSION_ID:-default}"
# Same sanitization /pause Step 7a applies. SESSION_ID is spliced into the jq
# path of the 0.5 resume receipt, so an unsanitized value would both break that
# path and fail to match the key /pause wrote.
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
REPO_KEY=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  # `_unknown` is the reserved no-repo-context bucket, not this repo's key —
  # probing it would read another checkout's leftovers as our own evidence.
  [[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
fi
```

**An unresolved helper never reads as "no evidence".** Print `DEGRADED: <name> not found (checked both installed paths) — <class> detection unavailable, continuing without it` — both, not three, because the checkout candidate is deliberately excluded above — and carry that gap into the verdict: a class that could not be probed is *unknown*, not *absent*. With `session-state.sh` unresolved, only the on-disk marker and handoff-note globs remain; if those are also empty the verdict is **unclassifiable** (0.4), never "nothing to resume".

### 0.2a Validate an auto-wake generation (only when `--generation` was passed)

A wake that fires after its park was resumed, replaced, or adopted by another owner must change nothing. Validate **before** any probe runs, any gate is touched, or any work is re-armed — the same order and the same verdicts `/pause-resume` Step 0 uses, against the same field, so the two wake shapes cannot disagree. It runs here, immediately after 0.2, because it needs `SESSION_STATE_SH` and `REPO_KEY`; with `--generation` present and either unresolved, the run stops rather than continuing unvalidated.

<!-- test-anchor: go-on-limit-generation-gate -->

```bash
# Inputs: CALLER_GENERATION (from --generation), SESSION_STATE_SH, REPO_KEY.
# Output: GENERATION_VERDICT=valid|stale|blocked|absent
if [[ -z "${CALLER_GENERATION:-}" ]]; then
  GENERATION_VERDICT=absent            # ordinary manual /go-on — nothing to validate
elif [[ -z "${SESSION_STATE_SH:-}" || -z "${REPO_KEY:-}" ]]; then
  GENERATION_VERDICT=blocked           # cannot validate; change nothing
else
  STORED_RC=0
  STORED_GENERATION=$("$SESSION_STATE_SH" \
    --get ".repos[\"$REPO_KEY\"].day.limit_resume_generation" 2>/dev/null) || STORED_RC=$?
  if [[ "$STORED_RC" -ne 0 && "$STORED_RC" -ne 3 ]]; then
    GENERATION_VERDICT=blocked         # unreadable is never "no generation"
  elif [[ "$STORED_RC" -eq 3 || -z "$STORED_GENERATION" || "$STORED_GENERATION" == "null" \
          || "$CALLER_GENERATION" != "$STORED_GENERATION" ]]; then
    GENERATION_VERDICT=stale
  else
    GENERATION_VERDICT=valid
  fi
fi
printf 'GENERATION_VERDICT=%s\n' "$GENERATION_VERDICT"
```

- **`valid`** → continue to 0.3. The park is still this wake's to resume.
- **`stale`** → print `Stale auto-wake rejected; nothing was resumed.` and **exit 0**. No gate cleared, no probe run, no receipt written, no launch.
- **`blocked`** → print one line naming the read failure and exit 1. An unreadable generation is not a licence to resume.
- **`absent`** → a manual invocation; the ladder runs normally.

### 0.3 Probe the evidence

Run every probe — classification needs the full picture, not the first hit.

**A — planned-stop gate** (repo-scoped, outlives the session that armed it; the authority for newest-wins):

```bash
GATE_JSON='{}'
GATE_STATE=unreadable            # unreadable | absent | present — never default to absent
if [[ -z "$SESSION_STATE_SH" || -z "$REPO_KEY" ]]; then
  GATE_STATE=unreadable          # helper or repo identity missing: cannot rule the class out
else
  PAUSES=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].execution_pauses" 2>/dev/null)
  READ_RC=$?
  if (( READ_RC == 3 )); then
    GATE_STATE=absent            # exit 3 is "no state file" — genuinely nothing recorded
  elif (( READ_RC != 0 )); then
    GATE_STATE=unreadable        # 4/5/anything else: a read that failed, not an empty map
  elif GATE_JSON=$(jq -ce '
      if type != "object" and type != "null" then error("not a map") else . end
      | (. // {}) | to_entries
      | map(select(.value.active == true and (.value.cleared_at // null) == null))
      # An active record must be self-describing: a known command and a UTC Z
      # stamp. Anything else is unorderable evidence, not an absent gate.
      | if any(.value.command != "end" and .value.command != "pause")
             or any((.value.at // "") | test("^[0-9]{4}(-[0-9]{2}){2}T([0-9]{2}:){2}[0-9]{2}Z$") | not)
        then error("invalid active gate record") else . end
      | sort_by(.value.at) | last
      | if . == null then {}
        else {class: .value.command, at: .value.at, session: .key} end
    ' <<<"${PAUSES:-null}"); then
    # `jq -e` exits 1 only on a `null`/`false` result; every success path here
    # emits an object, so exit 0 means "read and validated", not "non-empty".
    if [[ "$GATE_JSON" == '{}' ]]; then GATE_STATE=absent; else GATE_STATE=present; fi
  else
    GATE_JSON='{}'; GATE_STATE=unreadable   # malformed map or invalid active record
  fi
fi
GATE_CLASS=$(jq -r '.class // ""' <<<"$GATE_JSON")   # end | pause | "" (absent/unreadable)
GATE_AT=$(jq -r '.at // ""' <<<"$GATE_JSON")
```

`GATE_STATE=unreadable` is **unclassifiable evidence, not an absent gate** — ranks 2 through 5 are all barred outright (0.4). Resuming an `unplanned` or `token_exhaustion` lane while a planned stop may be armed is the exact mistake the ladder exists to prevent: the gate would block every successor launch, and the parked board would go unread. Rank 3 is barred for the same reason as ranks 4 and 5 and on the same evidence — continuing a recorded phase is a resume like any other, and a token-exhaustion handoff is not evidence that no `pause` or `end` gate is armed. Only `GATE_STATE=absent` — an unambiguous "no record" — lets the ladder fall through. The single exception is a validated `--generation` (0.2a), which names one specific park record rather than inferring the class from the gate.

Also read this session's own gate — it decides whether new launches are blocked right now. The helper prints `active` | `inactive` and exits 0; an unresolved helper or a failed call is `unreadable`, which feeds the unclassifiable rule in 0.4, never `inactive`:

```bash
GATE_LIVE=unreadable
if [[ -n "$EXECUTION_PAUSE_SH" ]]; then
  GATE_LIVE=$("$EXECUTION_PAUSE_SH" --status --session "$SESSION_ID" 2>/dev/null) || GATE_LIVE=unreadable
  [[ "$GATE_LIVE" == active || "$GATE_LIVE" == inactive ]] || GATE_LIVE=unreadable
fi
```

**B — parked `/pause` record:** the **union** of `.repos["$REPO_KEY"].pauses[*]` (session-keyed, issue #1576) and the legacy singletons `.pause` / `.suspend` (pre-#1310). Probe B is `present` when **any** record in that union is **un-resumed**; `record_at` is the newest such record's `paused_at` (legacy `suspended_at`).

**Un-resumed is the same predicate `/pause-resume` Step 1 selects on**, not `active == true`: a record closed with re-arms still outstanding is *partially* restored, `/pause-resume` re-selects it, and a probe that called it absent would report `nothing to resume` over work that command is still going to pick up. A missing or unparseable `active` counts as active.

**Read the whole map, never one slot.** A sibling session's record with `active: false` says only that *that* session's board was restored — it is never evidence that nothing else is parked, and reading a single slot is what let a later `/pause` hide an earlier one entirely. Read the map and both legacy slots and take the union:

```bash
# Three sources, three verdicts (issue #1611). `.pauses` and both legacy
# singletons are read in ONE uniform loop and classified EACH ON ITS OWN, so a
# damaged slot degrades alone: a failed read no longer breaks out of the loop,
# and an unparseable value no longer raises out of the combine, either of which
# threw away the healthy slots read beside it.
#
# Same tri-state rule probe A applies: exit 3 is the one unambiguous "no state
# file"; every other non-zero — an unresolved helper included — is UNREADABLE
# for that slot and must not let it read `absent`.
#
# The legacy singletons are read UNCONDITIONALLY, on the same rule and in the
# same loop. They are union members, never an else-branch taken only when
# `.pauses` is empty: gating the legacy read on an empty map is this very bug one
# level up — a pre-upgrade board becomes unreachable the moment any keyed record
# exists.
PAUSES_RAW=""
LEGACY_PAUSE_RAW=""
LEGACY_SUSPEND_RAW=""
# The names of the slots that could not be read or would not parse. Empty means
# every slot was readable; a name here is reported and that slot alone dropped.
PAUSE_SLOTS_UNREADABLE=""
if [[ -z "$SESSION_STATE_SH" || -z "$REPO_KEY" ]]; then
  # No helper or no repo identity reaches none of them — that is three unreadable
  # slots, not an absent probe.
  PAUSE_SLOTS_UNREADABLE="pauses pause suspend"
else
  for PAUSE_SLOT in pauses pause suspend; do
    SLOT_RAW=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].$PAUSE_SLOT" 2>/dev/null)
    SLOT_RC=$?
    if (( SLOT_RC == 3 )); then SLOT_RAW=""   # no state file — the absence probe A already saw
    elif (( SLOT_RC != 0 )); then
      SLOT_RAW=""
      PAUSE_SLOTS_UNREADABLE="${PAUSE_SLOTS_UNREADABLE:+$PAUSE_SLOTS_UNREADABLE }$PAUSE_SLOT"
    fi
    case "$PAUSE_SLOT" in
      pauses)  PAUSES_RAW="$SLOT_RAW" ;;
      pause)   LEGACY_PAUSE_RAW="$SLOT_RAW" ;;
      suspend) LEGACY_SUSPEND_RAW="$SLOT_RAW" ;;
    esac
  done
fi
PAUSE_PROBE=$(jq -c -n \
  --arg keyed  "${PAUSES_RAW:-null}" \
  --arg lpause "${LEGACY_PAUSE_RAW:-null}" \
  --arg lsusp  "${LEGACY_SUSPEND_RAW:-null}" '
  # ---- one slot, one verdict (issue #1611) -----------------------------------
  # Classify a single pause source on its OWN: `absent` (null), `present` (the
  # shape that slot holds), or `unreadable` (anything else). The session-keyed
  # map and the legacy singletons take the SAME rule — only `$kind` differs,
  # because only the shape differs — so a corrupt map is named exactly the way a
  # corrupt singleton is, and neither is ever read as "nothing parked".
  # This definition is identical in /pause-resume Step 1, /go-on probe B, and
  # here; pause-multisession.test.sh extracts all three and fails if they drift.
  def slot_class($kind):
    if type == "null" then "absent"
    elif $kind == "map"
      then (if type == "object" and (to_entries | all(.value | type == "object"))
            then "present" else "unreadable" end)
    elif type == "object" then "present"
    else "unreadable" end;
  # A damaged slot names itself and nothing else. The caller degrades exactly
  # the slots listed here, so every surviving slot still contributes.
  def slot_degraded($name; $kind):
    if slot_class($kind) == "unreadable" then [$name] else [] end;
  # ---- end shared per-slot validation ----------------------------------------
  def pend($a): ($a | if type == "array"
                      then map(select((type != "object") or ((.rearmed // false) != true))) | length
                      else 0 end);
  def unresumed: (.active != false)
                 or ((pend(.monitors_stopped) + pend(.background_tasks_stopped)) > 0);
  # An empty read is "nothing there". A value that will not parse is a DAMAGED
  # slot, not an empty one — caught HERE, inside the slot, so it classifies as
  # `unreadable` rather than aborting the program and taking the other two with
  # it. The caught value is a string, which slot_class already calls unreadable.
  def parse: if . == "" then null else (try fromjson catch "unparseable") end;
  # Only a `present` slot contributes records; a damaged one contributes none
  # and is reported by name instead.
  def slot_records($kind):
    if slot_class($kind) != "present" then []
    elif $kind == "map" then (to_entries | map(.value))
    else [.] end;
  { records: ( (($keyed  | parse) | slot_records("map"))
             + (($lpause | parse) | slot_records("slot"))
             + (($lsusp  | parse) | slot_records("slot"))
             | map(select((type == "object") and unresumed))
             # Newest first, on either spelling of the timestamp (legacy: `suspended_at`).
             | sort_by(.paused_at // .suspended_at // "") | reverse ),
    degraded: ( (($keyed  | parse) | slot_degraded("pauses"; "map"))
              + (($lpause | parse) | slot_degraded("pause"; "slot"))
              + (($lsusp  | parse) | slot_degraded("suspend"; "slot")) ) }' 2>/dev/null)
if [[ -z "$PAUSE_PROBE" ]]; then
  # The combine itself failed — no slot can be vouched for.
  PAUSE_UNRESUMED=""
  PAUSE_SLOTS_UNREADABLE="pauses pause suspend"
else
  PAUSE_DAMAGED=$(jq -r '.degraded | join(" ")' <<<"$PAUSE_PROBE")
  [[ -z "$PAUSE_DAMAGED" ]] || \
    PAUSE_SLOTS_UNREADABLE="${PAUSE_SLOTS_UNREADABLE:+$PAUSE_SLOTS_UNREADABLE }$PAUSE_DAMAGED"
  PAUSE_UNRESUMED=$(jq -c '.records' <<<"$PAUSE_PROBE")
  # Probe B is `unreadable` only when a damaged slot is ALL there is. A surviving
  # slot's un-resumed record is `present` evidence no matter what its damaged
  # sibling holds — that is the whole point of degrading per slot.
  if [[ -n "$PAUSE_SLOTS_UNREADABLE" && "$PAUSE_UNRESUMED" == "[]" ]]; then
    PAUSE_UNRESUMED=""
  fi
fi
# Name every damaged slot to the user; the slots not named here still counted.
[[ -z "$PAUSE_SLOTS_UNREADABLE" ]] || \
  echo "DEGRADED: pause slot(s) $PAUSE_SLOTS_UNREADABLE unreadable — records there were not consulted; the other pause slots were" >&2
```

The union above is the whole of probe B — the legacy slots are read and sorted in
that same program, not left to a follow-up step. The two empties are distinct and must stay so: `PAUSE_UNRESUMED` holding `[]` means every readable slot was consulted and nothing is parked — `absent`; holding `""` means no slot could be vouched for — `unreadable`, never `absent` (§Degradation).

**Degradation is per slot (issue #1611).** A `.pauses` value that is neither null nor a map of records is corrupt, and so is a legacy slot holding anything but a record — but a damaged slot is *named* in `PAUSE_SLOTS_UNREADABLE` and dropped **alone**, never collapsed to `[]` and never raised out of the combine. The surviving slots still produce their records, so probe B reads `present` on a healthy keyed board even while `.pause` is corrupt; it falls to `unreadable` only when a damaged slot is all there is. The `slot_class` rule doing the classifying is verbatim-identical in `/pause-resume` Step 1 and `candidate-ownership.sh`, and `pause-multisession.test.sh` fails if the three drift.

If the state read fails, the existence of any `~/.claude/handoffs/pause-*.md` or `suspend-*.md` is a pause **candidate** — `/pause-resume` Step 1 owns marker selection and fails closed with `No parked session found` when the marker belongs to another repo, so a false candidate costs a no-op, never a wrong restore.

**C — `/end` record:** the canonical note for this repo, `~/.claude/handoffs/portable-handoff-<owner>-<repo>-*.md` with the repo key lowercased and `/` replaced by `-`, **excluding** `*-checkpoint.md` (those are automatic checkpoints, which stop nothing — probe E). Corroborating: `refill == {paused: true, reason: "full_stop"}`, which both `/end` and `/pause` write and which therefore never discriminates between them on its own.

**D — token-exhaustion handoff:** any `.repos["$REPO_KEY"].prs[*]` entry with `handoff_reason == "token_exhaustion"` (schema: `session-state-schema.json` `_token_exhaustion_example`), carrying `phase`, `needs`, `head_sha`, and `remaining_work`. Corroborate against the scoped handoff file (`"$HANDOFF_STATE_SH" --owner-repo <owner>/<repo> --get <N>`).

**E — unplanned interruption** (crash, compaction, sign-out — no planned-stop record at all): any of a registry entry still `running`/`stopping`/`stop_failed` (`"$TASK_REGISTRY_SH" --list --live`), a `.repos["$REPO_KEY"].prs` entry, a scoped handoff file for this branch's PR, a `*-checkpoint.md` note for this repo, an in-progress rebase, or a feature branch with uncommitted/unpushed work or an open PR.

**F — usage-limit park** (issue #1618): at least one `.repos["$REPO_KEY"].prs[*]` entry whose `handoff_reason == "usage_limit_park"`, carrying `phase`, `head_sha`, and `remaining_work` (schema: `session-state-schema.json` `_usage_limit_park_example`). The repo park record at `.repos["$REPO_KEY"].day` decides only *whether the window is still shut*: a non-null `parked_until` in the future sets `PARK_ACTIVE`, and the park record **alone**, with no per-PR entries, is day mode's business (`/pm` 2D.5 owns it) and reads `absent` here. It is the per-PR records that make this a *subagent-thread* park with pipelines to relaunch, so **they are what the probe keys on** — a retired `parked_until` over surviving records is a resume-now park, not an absent one (`/pause-resume` Step 5 retires the park fields before its relaunches land, and leaves the flag set on any that did not). Corroborate each against its scoped handoff file (`"$HANDOFF_STATE_SH" --owner-repo <owner>/<repo> --get <N>`): the handoff's `phase_completed` is what decides which phase relaunches, and a record the handoff cannot support is reported, never resumed. Same tri-state rule as every probe above — only exit 3 is "no state file"; anything else is `unreadable`, never `absent`.

<!-- test-anchor: go-on-limit-park-probe -->

```bash
# Inputs: SESSION_STATE_SH, REPO_KEY. Outputs: PARK_PROBE=present|absent|unreadable,
# PARK_PIPELINES (JSON array of {pr, phase, head_sha, needs}), PARK_ACTIVE
# (true while parked_until is still in the future) and PARK_WAIT_S.
PARK_PROBE=unreadable
PARK_PIPELINES="[]"
PARK_ACTIVE=false
PARK_WAIT_S=0
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  PU_RC=0
  PARK_UNTIL=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.parked_until" 2>/dev/null) || PU_RC=$?
  PRS_RC=0
  PRS_RAW=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].prs" 2>/dev/null) || PRS_RC=$?
  if (( PU_RC == 3 )) && (( PRS_RC == 3 )); then
    PARK_PROBE=absent
  elif (( PU_RC != 0 && PU_RC != 3 )) || (( PRS_RC != 0 && PRS_RC != 3 )); then
    PARK_PROBE=unreadable
  elif [[ -n "$PARK_UNTIL" && "$PARK_UNTIL" != "null" \
          && ! "$PARK_UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    # Canonical UTC `Z`, or it is damaged evidence. Validate the SHAPE before
    # either parser, because the two disagree about what is valid: GNU `date -d`
    # accepts relative words ("tomorrow", "now", "+1 day") and would turn a
    # corrupt field into a plausible epoch, skipping the `unreadable` verdict
    # entirely, while BSD `date -j -f` rejects them — so the same record would
    # classify differently on Linux and macOS. The format gate makes both agree.
    PARK_PROBE=unreadable
  elif [[ -n "$PARK_UNTIL" && "$PARK_UNTIL" != "null" ]] \
       && ! PARK_EPOCH=$(date -u -d "$PARK_UNTIL" +%s 2>/dev/null \
                         || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PARK_UNTIL" '+%s' 2>/dev/null); then
    # A park record whose timestamp will not parse is damaged evidence, not an
    # absent park — same rule the recovery block applies, and the same reason:
    # falling through would let a lane launch into a window nothing can date.
    PARK_PROBE=unreadable
  elif [[ -n "$PARK_UNTIL" && "$PARK_UNTIL" != "null" && ! "$PARK_EPOCH" =~ ^[0-9]+$ ]]; then
    PARK_PROBE=unreadable
  elif PARK_PIPELINES=$(jq -ce '
      # Same corruption rule probe B applies: a `.prs` that is neither a map nor
      # null is damaged, not empty. Without this an ARRAY would take to_entries
      # silently, and its numeric indices would read as fabricated PR numbers.
      (if type != "object" and type != "null" then error("prs is not a map") else . end)
      | (. // {}) | to_entries
      | map(select((.value.handoff_reason // "") == "usage_limit_park"))
      | map({pr: .key,
             phase:    (.value.usage_limit_park.phase     // .value.phase     // ""),
             head_sha: (.value.usage_limit_park.head_sha  // .value.head_sha  // ""),
             needs:    (.value.usage_limit_park.needs     // .value.needs     // "")})
      # A record flagged parked but missing any of the three fields the resume
      # needs is damaged evidence, exactly like the unparseable timestamp and
      # the non-map `.prs` above — so it takes the same `unreadable` verdict
      # rather than reporting as resumable with empty strings standing in for a
      # phase nobody recorded.
      | if any(.[]; .phase == "" or .head_sha == "" or .needs == "")
        then error("parked record missing phase/head_sha/needs") else . end
    ' <<<"${PRS_RAW:-null}" 2>/dev/null); then
    if [[ "$PARK_PIPELINES" == "[]" ]]; then
      # No per-PR records: not a subagent-thread park, whatever `parked_until`
      # says. A standing repo park on its own is day mode's business (`/pm` 2D.5
      # owns it), exactly as this probe's prose states.
      PARK_PROBE=absent
    elif [[ -z "$PARK_UNTIL" || "$PARK_UNTIL" == "null" ]]; then
      # Records OUTLIVE a retired `parked_until` (#1618), so the `.prs` scan runs
      # whether or not the repo park still stands. `/pause-resume` Step 5 retires
      # the six park fields in ONE write and only then relaunches, deliberately
      # leaving `handoff_reason == "usage_limit_park"` set on any PR whose
      # relaunch did not land "so the next pass can retry it". Gating this scan
      # on `parked_until` is what made that next pass blind: the orphaned records
      # were unreachable by every later `/go-on`, and the retry the delegation
      # lane promises could never happen. The window is demonstrably open — the
      # park that closed it is gone — so this is a resume-now park, never a wait.
      PARK_PROBE=present
      PARK_ACTIVE=false
      PARK_WAIT_S=0
    else
      PARK_PROBE=present
      # Is the window still shut? The wake fires at reset + 2 minutes, so by the
      # time it runs `parked_until` is already past and PARK_ACTIVE is false. A
      # MANUAL /go-on before then must not relaunch into the closed window.
      PARK_WAIT_S=$(( PARK_EPOCH - $(date -u +%s) ))
      if [ "$PARK_WAIT_S" -gt 0 ]; then PARK_ACTIVE=true; else PARK_WAIT_S=0; fi
    fi
  else
    PARK_PIPELINES="[]"; PARK_PROBE=unreadable
  fi
fi
printf 'PARK_PROBE=%s\nPARK_ACTIVE=%s\nPARK_WAIT_S=%s\nPARK_PIPELINES=%s\n' \
  "$PARK_PROBE" "$PARK_ACTIVE" "$PARK_WAIT_S" "$PARK_PIPELINES"
```

### 0.4 Precedence — first match wins

| Rank | Class | Fires on | Resume action |
|---|---|---|---|
| 1 | `pause` / `end` | A `present`; or A `absent` with exactly one of B / C | Delegate: `/pause-resume [--resume-refill]` or `/end-resume [--resume-refill]` |
| 2 | `usage_limit_park` | F `present`, **and** every planned-stop probe readable; or `--generation` validated `valid` in 0.2a | Relaunch each parked pipeline at its recorded phase (0.6) |
| 3 | `token_exhaustion` | D, **and** every planned-stop probe readable | Continue the recorded phase (0.6) |
| 4 | `unplanned` | E only, **and** every planned-stop probe readable | Steps 0b–10 below |
| 5 | `none` | nothing, and every probe readable | Report `nothing to resume`; change no state |

**Explicit parked state outranks generic stall detection.** A readable planned-stop record wins over in-flight-looking branch state every time: rank 4 is reached only when ranks 1–3 found nothing. A planned stop also outranks ranks 2 and 3 because its gates are armed, and only `/pause-resume` / `/end-resume` may clear them (`phase-protocols.md` §"Launch gate before every successor").

**A validated `--generation` outranks probe A.** The usage-limit park closes the same execution gate `/pause` does, so probe A reads `present` with `command: pause` on every parked board — and rank 1 alone would delegate to `/pause-resume`, which re-arms live runtime IDs and would leave every dead pipeline stopped. A generation that 0.2a validated is the park record naming this invocation as its own wake, which is stronger evidence than the gate it armed itself. So `GENERATION_VERDICT == valid` selects rank 2 — **but only when probe F is readable**. A validated token says which park armed this wake; it says nothing about whether that park's record can still be read, and rank 2 retires the park and relaunches pipelines, both of which need a record that parses. F `unreadable` with a valid generation is therefore `unclassifiable` (report the read failure, retire nothing, relaunch nothing), and F `absent` with a valid generation falls through to rank 1 — the day-mode park case, whose wake this same `/go-on` serves by forwarding the generation to `/pause-resume` (0.6). Without `--generation`, F is ranked on its evidence like any other probe and rank 1 keeps precedence.

**F `unreadable` blocks ranks 3, 4, and 5**, on the same rule that makes `GATE_STATE=unreadable` block them: a park that could not be read cannot be ruled out, and relaunching an `unplanned` lane into a still-closed window is the failure this rank exists to prevent.

**`pause` vs `end` — newest wins, decided by probe A.** Each activation writes `command` + `at` in the same UTC `Z` format, so the newest active entry names the class. Corroborating records (B, C) settle it only when A is missing or unreadable, and cannot order two classes against each other — their timestamps are not comparable (one ISO string, one file mtime).

**Unclassifiable → report, never guess** (`[BLOCKED]`, no state change, no launch). Print what was found, then offer the resolution paths as a menu (`ask-menu.md`; prose fallback when headless). The cases:
- `PARK_PROBE=unreadable` with a validated `--generation` — the wake names a park whose record will not parse. Retire nothing and relaunch nothing; report the read failure and the generation it arrived with.
- `GATE_STATE=unreadable` — the planned-stop record could not be read or carries an active entry with an unknown `command` or a non-UTC-`Z` `at`. A `pause` or `end` may be armed, so ranks 2 through 5 are all barred — including rank 3 even when a token-exhaustion handoff (D) is present and readable. The one exception is a `--generation` that 0.2a validated: that token names a specific park record, so it identifies the stoppage without the gate having to.
- B and C both present, A `absent` or unreadable — two planned stops that cannot be ordered. Options: `/pause-resume`, `/end-resume`.
- This session's gate is `active` — or `GATE_LIVE=unreadable` — and no class is readable from A, B, or C.
- A probe could not be *read* (0.2) and its class cannot be ruled out.
- A pause record in the probe-B union says `active: true` but `/pause-resume` reports no state and no marker — name the record's session key.
- More than one token-exhaustion entry (D) and none matches the current branch's PR — name every PR found.

### 0.5 Resume receipt — never resume the same stoppage twice

Read **this session's own** receipt at `.repos["$REPO_KEY"].resumes["$SESSION_ID"]` before dispatching, where `$SESSION_ID` is `${CLAUDE_SESSION_ID:-default}` under the same `[^[:alnum:]_.-] -> _` sanitization `/pause` Step 7a applies. Build the evidence digest `class|record_at|pr|head_sha|branch`. **On the `usage_limit_park` class the `pr|head_sha` slot carries every parked PR**, as `pr:head_sha` pairs sorted by PR number and joined with `,` — not one representative pair. A park is routinely a *set* of pipelines, and a single pair cannot tell a fully-resumed board from a partly-resumed one: dispatch four, land three, and the digest built on the same representative PR is byte-identical, so the next `/go-on` matches its own receipt and answers `[DONE]` while one pipeline is still parked. Keyed on the whole set, any PR that remains parked changes the digest and the retry happens. If it equals the receipt's `evidence_digest` and `--again` was not passed:

```
[DONE] nothing to resume — the <class> stoppage recorded at <record_at> was already
       resumed at <receipt .at> via <receipt .dispatched_to>. Re-run with --again
       to force a pass.
```

`<receipt .at>` is the receipt's `at` field — when the previous resume ran, not when the stoppage was recorded. Arm nothing, launch nothing, write nothing. After a **successful** dispatch (ranks 1–4 only), write the receipt in one call:

```bash
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].resumes[\"$SESSION_ID\"]=$RESUME_JSON"
```

`RESUME_JSON` is `{class, evidence_digest, at, session_id, dispatched_to}`, where `at` is now. Rank 5 writes nothing at all — "nothing to resume" is a read-only verdict.

**Receipts are keyed per session (issue #1576).** As a repo singleton the receipt was a cross-session mask: whichever session dispatched last was the only one recorded, so a sibling's "already resumed" verdict could suppress a dispatch while that session's own pause record was still un-resumed — silent data loss with no error anywhere. `--set` on one map key preserves the others, so concurrent `/go-on` runs never overwrite each other.

**The legacy singleton `.resume` is read only when it is this session's.** Consult `.repos["$REPO_KEY"].resume` only when the map holds no entry for this session **and** the legacy block's `session_id` matches `$SESSION_ID` or is absent. An unconditional legacy read would reinstate exactly the mask this change removes, in a different slot:

```bash
# Tri-state, like every other stop-state read: only exit 3 is "no state file".
# An unreadable receipt must not read as "no receipt" — that would re-dispatch a
# stoppage this session may already have resumed, which is the duplicate the
# receipt exists to prevent. Report and stop before dispatching.
read_receipt() { # read_receipt <jq-path> -> RECEIPT_VALUE, RECEIPT_STATE
  local _rc=0
  RECEIPT_VALUE=""; RECEIPT_STATE=unreadable
  RECEIPT_VALUE=$("$SESSION_STATE_SH" --get "$1" 2>/dev/null) || _rc=$?
  case "$_rc" in
    0) RECEIPT_STATE=present ;;
    3) RECEIPT_VALUE=""; RECEIPT_STATE=absent ;;
    *) RECEIPT_VALUE=""; RECEIPT_STATE=unreadable ;;
  esac
}
read_receipt ".repos[\"$REPO_KEY\"].resumes[\"$SESSION_ID\"]"
RECEIPT="$RECEIPT_VALUE"
if [[ "$RECEIPT_STATE" == unreadable ]]; then
  echo "[BLOCKED] the resume receipt for this session could not be read — not dispatching," >&2
  echo "          because re-running a stoppage already resumed is what the receipt prevents." >&2
  exit 1
fi
if [[ -z "$RECEIPT" || "$RECEIPT" == "null" ]]; then
  read_receipt ".repos[\"$REPO_KEY\"].resume"
  if [[ "$RECEIPT_STATE" == unreadable ]]; then
    echo "[BLOCKED] the legacy resume receipt could not be read — not dispatching." >&2
    exit 1
  fi
  LEGACY="$RECEIPT_VALUE"
  if [[ -n "$LEGACY" && "$LEGACY" != "null" ]]; then
    LEGACY_SESSION=$(jq -r '.session_id // ""' <<<"$LEGACY" 2>/dev/null || echo "")
    [[ -z "$LEGACY_SESSION" || "$LEGACY_SESSION" == "$SESSION_ID" ]] && RECEIPT="$LEGACY"
  fi
fi
```

**A receipt never outranks a still-parked board.** `record_at` in the digest is the newest **un-resumed** record's timestamp (probe B), so a record that is still parked keeps producing a digest, and a record that was genuinely restored stops appearing in the union and changes the digest. A `nothing to resume` verdict therefore rests on the records themselves, with the receipt only suppressing a repeat of the *same* evidence for the *same* session.

### 0.6 Dispatch

**Never duplicate a live task or Monitor.** Before any lane, list live registry entries (`"$TASK_REGISTRY_SH" --list --live`) and read `.prs["<N>"].babysit.active`. Work already covered by a live identity is reported, not relaunched; the delegated commands take the locked `stopped -> rearming` claim that makes concurrent resumes single-writer.

An unresolved `background-task-registry.sh` or a failed listing is an **unreadable inventory, never an empty one** (the same rule `/pause` Step 0 applies): say the live-task check could not run, and do not launch anything in the `unplanned` or `token_exhaustion` lanes on the assumption nothing is running. Delegation to `/pause-resume` / `/end-resume` still proceeds — their own claims are locked, so they cannot double-launch on a blind check.

- **`pause` / `end`** — invoke `/pause-resume` or `/end-resume`, forwarding `--resume-refill` when given, **and `--generation` when 0.2a validated one**. Forwarding it is what lets a single re-armed `/go-on` wake serve a day-mode park too: with no per-PR park records the ladder falls here, and `/pause-resume` re-validates the same token against the same field before clearing anything. They clear the execution gate, re-arm stopped work, and own the refill decision. Report their outcome; do not re-run their steps here.
- **`usage_limit_park`** — **only once the window has reopened.** `PARK_ACTIVE=true` means `parked_until` is still in the future: report `parked until <parked_until> — <PARK_WAIT_S>s remaining; resuming automatically when the wake fires` and relaunch nothing, on a manual run and on a `--generation` wake alike (a wake that fires early is a wake whose deadline was mis-derived, and dispatching on it walks straight back into the wall). With the park expired, delegate the whole resume to `/pause-resume --generation "$CALLER_GENERATION"` (omit the flag on a manual run) and **relaunch nothing here**. It owns the execution gate, disarms any still-armed wake, retires the six park fields in one write, and — since issue #1618 — its Step 5 relaunches the parked pipelines themselves, claiming each PR before it launches. `PARK_PIPELINES` is this lane's *expectation*, not a second work list: relaunching from it after Step 5 has already run is how one park becomes two Phase B or C pipelines on one branch, because the list was captured before the delegation and knows nothing of the claims Step 5 took. This is the same rule the `pause` / `end` lane states — report their outcome; do not re-run their steps here — and it is what keeps the design's promise of one set of records, two entry points, and no second resume route.

Then **reconcile and report, without launching**: re-read `.prs[*]` and compare against `PARK_PIPELINES`. An entry that no longer carries `handoff_reason == "usage_limit_park"` **and no longer carries `usage_limit_relaunching` either** was relaunched by Step 5 — report it as resumed. One reading `usage_limit_relaunching` is *claimed*, which is not the same thing: the claim is taken before the launch, so the value alone says a thread intended to relaunch it, never that anything is running. Report it as claimed-not-confirmed and name it, so a claim whose thread died is visible here instead of being counted as a resume; Step 5's own stale-claim reclaim is what returns it to the retryable set on the next pass. One still carrying it was left behind deliberately (a launch gate declined it, its handoff is missing or contradicts the record, or another thread holds `usage_limit_relaunching`); name it and the reason Step 5 gave, and leave it parked for the next pass rather than launching it here to "finish the job". If the re-read fails, say the reconciliation could not run and name `PARK_PIPELINES` as the unverified expectation — never report those PRs as resumed on an unreadable check. When a parent orchestrator is live for that PR, its `phase-protocols.md` replacement path is preferred and this lane says so rather than racing it — the same rule the token-exhaustion lane follows. Procedure: `.claude/reference/subagent-thread-limit-park.md` §5.
- **`token_exhaustion`** — read the entry's `phase`, `head_sha`, and `remaining_work`, then continue that phase: enter Steps 0b–10 at the step its `needs` names (`continue_polling` → Step 6, unpushed fixes → Step 1b). The parent's replacement-subagent path (`phase-protocols.md`) is unchanged and still preferred when a parent orchestrator is live — say so rather than racing it.
- **`unplanned`** — continue to Step 0b. This is the original `/go-on` behavior, unchanged.
- **Monitors and artifact watches that died with the session are not re-armed here.** They belong to their owning skills' recovery paths (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`, `monitor-mode.md` §PM Monitoring Recovery) — the same ones `/pause-resume` Step 5 delegates to. Name what was found and which command owns it.

---

## Step 0b: Identify context

Reached only from Step 0's `unplanned` or `token_exhaustion` dispatch — the interrupted-review-workflow lane.

```bash
BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"
```

If on `main`, stop: `nothing to resume — on main, no interrupted workflow for this checkout` (rank 4; change no state).

Check if a PR exists:
```bash
gh pr view --json number,title,headRefName,state 2>/dev/null
```

Determine the {owner}/{repo} from git remote:
```bash
gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'
```

> **Authorship guard (issue #733, `safety.md`).** `/go-on` resumes a write workflow (push, review triggers, thread resolution, merge). Confirm you authored the PR before resuming any write step:
> ```bash
> PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null)
> [ -n "$PR_NUM" ] && "$PR_AUTHORSHIP_SH" "$PR_NUM"   # exit 0 = yours
> ```
> Not yours (exit 1) or undetermined (exit 4) → `[BLOCKED]`: "PR #$PR_NUM is not yours — the authorship guard blocks automated writes; name it explicitly to override." Proceed only under an explicit per-PR user override (say you are operating under it). Read-only status inspection is fine.

---

## Step 1: Check for an inherited rebase / conflict resolution (issue #757)

**Run this before Step 1b and before any commit or push.** The incident that motivated this guard was exactly a resumed session: an interrupted rebase left a resolution with no conflict markers that was nonetheless byte-identical to main — the whole fix the PR existed to deliver had been silently dropped, and every other gate (clean status, green CI, review) passed it.

```bash
GUARD="$DIFF_SURVIVAL_SH"
REBASE_IN_PROGRESS=0
{ [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; } && REBASE_IN_PROGRESS=1
SNAPSHOT_PRESENT=$("$GUARD" status --json | jq -r '.present')
```

- **Neither** a rebase in progress nor a snapshot on disk → `[SKIP]` — no inherited resolution to verify. Go to Step 1b.
- **Otherwise** (mid-rebase, or a snapshot left by a just-completed rebase) → `[ACTION]`:

  ```bash
  "$GUARD" snapshot --if-absent   # mid-rebase this reconstructs from orig-head, not the half-replayed HEAD
  "$GUARD" verify; GUARD_RC=$?
  ```

  - `0` — `[DONE]` diff survived the resolution; continue. (`deferred` also exits 0: commits are still queued for replay — finish the rebase, then re-run before pushing.)
  - `1` — `[BLOCKED]` the branch's entire diff vanished. Report the guard's output verbatim, including its one legitimate case (main independently landed the identical change → **close the PR**, never force-push an empty branch). Do not commit, push, or "fix" anything.
  - `2` — `[BLOCKED]` name the files that lost their changes and stop. This is an **unresolved conflict**, not a resumable state — re-resolve those files (whitespace-only survival still counts as lost), then re-run.
  - `4` — two shapes, both stop-and-report:
    - `unresolved_conflicts` → `[ACTION]` finish the resolution (optionally via `/merge-conflict`), then re-run `verify` before continuing.
    - `unverifiable` → `[BLOCKED]` the snapshot's baseline commit *is* the commit being checked, so it proves nothing. This is what a **just-completed** rebase with no snapshot looks like: a baseline cannot be reconstructed after the fact (`--if-absent` only reconstructs from `orig-head` while the rebase is still in progress). Say plainly that the resolution **cannot be verified**, and let the user decide — never report it as clean.
  - `5` — no snapshot could be established at all → `[BLOCKED]`: same handling as `unverifiable`. Never proceed silently on an unverifiable resolution.

  The guard never repairs; `git rebase --abort` or resetting to `ORIG_HEAD` stays the user's call. After a verified push completes, `"$GUARD" clear` retires the snapshot.

---

## Step 1b: Check for uncommitted changes

```bash
git status --porcelain
```

- If there are uncommitted changes: `[ACTION]` — Stage and commit changes. Ask the user for a commit message if the changes are ambiguous, otherwise use a descriptive message based on the diff.
- If clean: `[DONE]` — No uncommitted changes.

---

## Step 2: Run local CR review

Find the `coderabbit` CLI:
```bash
CR_BIN=$(which coderabbit 2>/dev/null || echo ~/.local/bin/coderabbit)
test -x "$CR_BIN" && echo "Found: $CR_BIN" || echo "Not found"
```

If available, run the local review loop:
```bash
$CR_BIN review --agent
```

- If findings are returned: `[ACTION]` — Fix all valid findings. Run `$CR_BIN review --agent` again after fixing.
- **Exit on 1 clean pass** (no findings returned) — `[DONE]` Local CR review passed.
- **Max 5 total iterations.** If you hit 5 runs without a clean pass, stop and report: `[BLOCKED]` — CR review not converging after 5 iterations.
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review instead:
  ```bash
  BASE=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || echo main)
  git diff "$BASE"...HEAD
  ```
- **After the local review loop completes**, classify and print coverage: `[COVERAGE] <level> — <reason>` (per `cr-local-review.md` "Coverage classification": `both | cr-only | codeant-only | none`). This flow reaches at most `cr-only` or `none`. For `none`, the line is mandatory before any push.

---

## Step 3: Push to remote

First refresh remote refs and check if the remote branch exists:
```bash
git fetch origin "$BRANCH" --quiet 2>/dev/null || true
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
```

- If the remote branch **does not exist**: `[ACTION]` — Pushing new branch:
  ```bash
  git push -u origin $BRANCH
  ```
- If the remote branch **exists**, check for unpushed commits:
  ```bash
  UNPUSHED=$(git log --oneline origin/$BRANCH..$BRANCH | wc -l | tr -d ' ')
  ```
  - If `UNPUSHED > 0`: `[ACTION]` — Pushing $UNPUSHED commits.
    ```bash
    git push origin $BRANCH
    ```
  - If `UNPUSHED == 0`: `[DONE]` — Branch is up to date with remote.

---

## Step 4: Ensure PR exists

```bash
PR_JSON=$(gh pr view --json number,title,body,state 2>/dev/null)
PR_NUM=$(printf '%s' "$PR_JSON" | jq -r '.number // empty')
```

Pipe with `printf '%s'`, never `echo` — zsh's builtin `echo` interprets the escape sequences in the PR body and corrupts the JSON, so `jq` errors and `PR_NUM` comes back empty, which reads as "no PR exists" (issue #574).

- If a PR exists and is open: `[DONE]` — PR #$PR_NUM exists. Additionally, always update the `**Local review coverage:**` line in the PR body: if coverage is `both`, remove any existing label (clearing stale degraded markers from prior runs); if coverage is degraded, replace the line if present or append it if missing. Fetch the PR body, apply the change, then `gh pr edit "$PR_NUM" --body "$UPDATED_BODY"`.
- If no PR exists: `[ACTION]` — Create one.
  - Look for an issue number from the branch name (pattern: `issue-N-*`):
    ```bash
    ISSUE_NUM=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
    ```
  - If `ISSUE_NUM` is empty (branch doesn't follow `issue-N-*` pattern): create the PR without a `Closes #N` footer. Note to user: "No linked issue detected from branch name."
  - If `ISSUE_NUM` is set: read the issue body for context:
    ```bash
    gh issue view $ISSUE_NUM --json title,body 2>/dev/null
    ```
  - Create the PR with a proper body (including `Closes #N` if issue was found) and a Test plan section. Include a `**Local review coverage:** <level>` labeled line when coverage is anything other than `both` (mandatory for `none` and single-CLI cases). After creation, capture the PR number:
    ```bash
    PR_NUM=$(gh pr view --json number --jq '.number')
    ```
- If the PR is merged: `[DONE]` — PR is already merged. Nothing to continue.
- If the PR is closed but not merged: `[BLOCKED]` — PR was closed without merging. It may need to be reopened or a new PR created.

---

## Step 5: Determine reviewer ownership

Resolve reviewer ownership via the shared helper (reads `.prs["<N>"].reviewer` from `~/.claude/session-state.json` first, falls back to a paginated live-history scan on all three comment endpoints):

```bash
REVIEWER=$("$REVIEWER_OF_SH" "$PR_NUM")
REVIEWER_EXIT=$?
```

Branch on exit code:
- `0` → `$REVIEWER` is one of `cr` / `bugbot` / `greptile`. Use it for Step 6.
- `1` → `unknown` printed; no bot has reviewed yet. Treat as **CR** (the default primary reviewer) and proceed to Step 6 to wait for the first review.
- `2` → `[BLOCKED]` — script/gh error; surface stderr.
- `3` → `[BLOCKED]` — PR #$PR_NUM not found (closed, merged, or invalid).
- `5` → `[BLOCKED]` — `~/.claude/session-state.json` is malformed, wrong shape, or the helper hit a runtime failure (e.g. a racing read between the validation guard and the jq lookup). Surface the helper's stderr, stop polling, and repair or remove the state file before retrying `/go-on`. Do **not** fall through to a live-history scan — sticky reviewer assignments live in session-state, and bypassing them risks mis-routing an already-escalated PR back to CR.

Output: `Reviewer: CR` / `Reviewer: BugBot` / `Reviewer: Greptile`.

---

## Step 6: Check for review response

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. The inline `gh api` calls below are legacy check-run and rate-limit spot-checks retained because they target commit-level endpoints (`/commits/{SHA}/check-runs`, `/commits/{SHA}/statuses`) not covered by `pr-state.sh`. For review, inline comment, and conversation endpoint lookups, use `pr-state.sh` exclusively.

### If PR is on CR:

Check the commit status for CodeRabbit:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status: .status, conclusion: .conclusion, title: .output.title}'
```

Also check the statuses endpoint as fallback:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/statuses" \
  --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {state: .state, description: .description}'
```

**Rate limit detection:** If check-run shows `conclusion: "failure"` with title containing "rate limit" (case-insensitive), OR status shows `description` containing "rate limit" — CodeRabbit reports this status as non-blocking `state: "success"`, so do not gate on `state`:
- `[ACTION]` — CR is rate-limited. Check BugBot (second-tier reviewer) before falling through to Greptile — BugBot auto-triggers on every push, so it may already have responded while CR was blocked:
  ```bash
  gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
    --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
  ```
  - BugBot has posted on `$SHA` → PR is now on **BugBot** (sticky). Persist and go to the BugBot section:
    ```bash
    "$REVIEWER_OF_SH" "$PR_NUM" --sticky bugbot
    ```
  - BugBot has NOT posted AND <10 min since push → `[ACTION]` — Waiting up to 10 min for BugBot's auto-review. Poll every 60 s.
  - BugBot has NOT posted AND ≥10 min since push → BugBot timed out. Fall through to Greptile:
    ```bash
    gh pr comment "$PR_NUM" --body "@greptileai"
    "$REVIEWER_OF_SH" "$PR_NUM" --sticky greptile
    ```
    Go to the Greptile section below.

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 7).

**Review pending:** If no completion signal and no rate-limit signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (12-minute timeout). A clean CR check-run completion short-circuits the timeout wait — but the merge gate still requires an explicit `APPROVED` review on the current HEAD SHA (per `cr-merge-gate.md` Step 1); completion alone does not satisfy it.
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- Check for rate-limit signals on every poll cycle. Rate-limit signals override the timeout — escalate immediately regardless of elapsed minutes.
- After 12 minutes with no review content and no rate-limit signal: `[ACTION]` — CR timed out. Check BugBot (same query as rate-limit path above). If BugBot has posted a review, persist `--sticky bugbot` and go to the BugBot section. If BugBot has also timed out (≥10 min since push), fall through to Greptile.

### If PR is on BugBot:

BugBot (`cursor[bot]`) is the second-tier free reviewer. Auto-triggers on every push; merge gate requires **1 clean BugBot review** on the current HEAD SHA (BugBot's completion signals are reliable).

Check for BugBot reviews on the current HEAD:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
```

Also check the BugBot check-run for the completion signal:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "Cursor Bugbot") | {status, conclusion}'
```

- BugBot has posted findings on `$SHA` → `[DONE]` — BugBot review received. Process findings (Step 7). After fixes are pushed, BugBot auto-reviews the new push; return to this section on the new SHA.
- BugBot has posted a clean review (check-run `completed` with no finding comments) on `$SHA` → `[DONE]` — merge gate met (1 clean pass is sufficient for the BugBot path). Proceed to merge verification.
- No BugBot response AND <10 min since push → `[ACTION]` — Polling for BugBot (10-min timeout from push). Poll every 60 s.
- No BugBot response AND ≥10 min since push → BugBot timed out. Fall through to Greptile immediately (after the Greptile budget gate). Do NOT extend the wait by triggering a manual `@cursor review` retry — the 10-min window from push is the hard timeout.
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews. Only escalate to Greptile if BugBot also fails.

### If PR is on Greptile:

Check for Greptile comments:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
```

- If Greptile has posted findings: `[DONE]` — Greptile review received. Process findings (Step 7).
- If no Greptile response: `[ACTION]` — Polling for Greptile (10-minute timeout). Polling cadence stays 60 s; exit immediately when the review lands, do not keep polling to 10 min.
  - If no response after 10 minutes: `[BLOCKED]` — Greptile timed out. Performing self-review as fallback. Note: self-review does NOT satisfy merge gate.

---

## Step 7: Check for unresolved findings

Fetch unresolved review threads (first 100 — sufficient for most PRs; if a PR has >100 threads, paginate using `pageInfo.endCursor`):
```bash
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {N}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}'
```

Count unresolved threads from reviewers:
- Filter for threads where any comment is from `coderabbitai[bot]`, `greptile-apps[bot]`, or `cursor[bot]`
- Only count threads where `isResolved == false`

Also check for issue-level review comments that may not have threads. Use the shared `pr-state.sh` helper — it fetches all three endpoints in one call, filters to `coderabbitai[bot]` / `greptile-apps[bot]` / `cursor[bot]` (BugBot), and pre-classifies each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$("$PR_STATE_SH" --pr "$PR_NUM" --since "$PR_CREATED")
jq '.new_since_baseline.conversation | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

- If there are unresolved findings: `[ACTION]` — Processing N unresolved findings.
  1. Read each finding carefully
  2. Verify against actual code before fixing
  3. Fix ALL valid findings in a single commit
  4. Push once
  5. Reply to every thread confirming the fix. Use the shared helper — it tries the inline `/replies` endpoint first, falls back to a PR-level comment on 404, and applies reviewer-specific `@mention` rules (prepends `@coderabbitai` for CR; strips `@cursor`/`@greptileai` for BugBot/Greptile):

     ```bash
     # $REVIEWER: cr | bugbot | greptile (determined from the finding's author)
     "$REPLY_THREAD_SH" <comment_id> --reviewer "$REVIEWER" \
       --body "Fixed in \`$SHA\`: <what changed>" --pr N
     ```

     Exit code `0` means the reply posted (by either the inline endpoint or the PR-level fallback); the fallback path also emits a note to stderr. Non-zero means a genuine failure to post. See `reply-thread.sh --help` for the full contract, including PR-number-unresolvable-without-`--pr` or both-endpoints-404 (exit 3) and inline-404-then-fallback-non-404 (exit 4).

  6. Resolve all bot threads with the shared helper (paginated, filtered to `coderabbitai`/`cursor`/`greptile-apps`, falls back to `minimizeComment` on failure):

     ```bash
     "$RESOLVE_REVIEW_THREADS_SH" "$PR_NUM"
     ```

     Exit 1 means at least one thread failed both mutations — surface to the user and stop. Do not proceed with a non-zero exit.

  7. After fixing, go back to **Step 6** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.

---

## Step 8: Check merge gate

Run the shared merge-gate verifier (implements CR 1 explicit APPROVED on current HEAD / BugBot 1-clean / Greptile severity + CI + BEHIND checks):

```bash
# CLEAN_BEHIND is state derived from THIS evaluation only. Clear it on entry —
# before the gate runs, ahead of every branch below, including exit 0 — because
# /go-on re-enters Step 8 (the rebase branch re-runs the gate, and Step 7 loops
# back through Step 6). A value left over from an earlier pass would re-enter
# Step 9a on a PR that is no longer BEHIND, where the re-probe returns exit 1
# ("mergeStateStatus is …, not BEHIND"), item 3 reads that as "genuinely not
# clean", and the branch is rebased and force-pushed a second time for nothing.
# Resetting inside the BEHIND bullet alone is NOT enough: the gate-exit-0 path
# never reaches that bullet.
CLEAN_BEHIND=0

GATE_JSON=$("$MERGE_GATE_SH" "$PR_NUM")
GATE_EXIT=$?
```

Branch on the exit code:

- `0` → `[DONE]` — Merge gate satisfied. Proceed to Step 9 (AC verification). `CLEAN_BEHIND` stays `0` here, so Step 9a correctly `[SKIP]`s: nothing about this pass is a clean-`BEHIND` follow-through.
- `1` → `[ACTION]` — Gate not met. Parse `missing` from the JSON output and act accordingly:
  - CR path with **"need 1 explicit CR APPROVED review on HEAD"**: if the current SHA is still within the 12-minute CR polling window, return to **Step 6** and keep polling — do NOT re-trigger yet. Only after the 12-minute timeout, and only within the 2-trigger-per-hour budget, post `@coderabbitai full review` once and return to **Step 6**.
  - CR path with **"CR approval on HEAD ... retracted by later CHANGES_REQUESTED"**: CR retracted approval. Return to **Step 7** to process the findings. Re-trigger only after fixes are pushed (the new SHA invalidates prior reviews regardless).
  - CR path with **"CodeRabbit check-run not green on HEAD"** or **"latest CR review on HEAD requests changes"**: CR has findings; return to **Step 7** to process them.
  - BugBot path with **"no BugBot review on HEAD"**: BugBot hasn't reviewed the current HEAD yet; return to **Step 6** to poll for the review.
  - BugBot path with **"latest BugBot review on HEAD has findings"**: return to **Step 7** to process findings.
  - Greptile path with **"unresolved Greptile thread(s)"**: return to **Step 7** to process; if P0 remains after fix, re-trigger `@greptileai` (subject to the 3-review cap per `.claude/rules/greptile.md`).
  - **"branch is BEHIND base"**: **probe before prescribing anything** (issue #1564). A *verified clean* `BEHIND` is an auto-merge, not a rebase — canonical in `.claude/rules/cr-merge-gate.md` Step 1d and `CLAUDE.md` "PR MERGE AUTHORIZATION" (issue #754), and encoded the same way in `.claude/agents/phase-c-merger.md` (issue #1563) and `fixpr/SKILL.md` Step 6. Rebasing a clean `BEHIND` moves HEAD, discarding the bot approval that had already satisfied the rest of the gate and restarting CI — the treadmill the carve-out exists to avoid.

    **Re-resolve the reviewer before probing — never reuse Step 5's variable.**
    Step 5 leaves `$REVIEWER` as the literal string `unknown` on its exit-`1`
    branch (its "treat as CR" instruction changes the *routing*, not the
    variable), and Step 6's escalations persist the new owner with
    `"$REVIEWER_OF_SH" --sticky …` **without** reassigning the shell variable. A
    bare `-n` guard therefore admits two wrong values: `--reviewer unknown` is a
    usage error (exit `2` → `[BLOCKED]`), and a stale `cr` after a
    BugBot/Greptile escalation gates the *wrong* path — a gate that can never go
    green, whose residual blocker reads as "not clean" and buys exactly the
    rebase this step exists to prevent. Validate the value and pass the flag
    **only** when it is one of the three the script accepts; otherwise omit it
    and let `merge-gate.sh` auto-detect, which reads the same sticky assignment
    Step 6 persisted. Same shape as `.claude/agents/phase-c-merger.md` Step 1
    (issue #1563).

    ```bash
    # Re-read rather than reuse: session-state holds any sticky escalation
    # Step 6 persisted, which never reached this shell's $REVIEWER.
    CB_REVIEWER=""
    RESOLVED_EXIT=0
    RESOLVED=$("$REVIEWER_OF_SH" "$PR_NUM") || RESOLVED_EXIT=$?
    if [[ "$RESOLVED_EXIT" -eq 5 ]]; then
      # Malformed session-state — STOP HERE, do not probe. Exit 5 is Step 5's
      # documented fail-fast, and omitting --reviewer would not be a safe
      # degradation: it lets merge-gate.sh fall through to a live-history guess
      # that can mis-route an already-escalated PR back to CR, mark a clean
      # BEHIND as unclean, and prescribe the rebase this step exists to prevent.
      # Report [BLOCKED] and leave CLEAN_BEHIND at 0; repair or remove
      # ~/.claude/session-state.json and re-run /go-on.
      echo "reviewer-of.sh exit 5: session-state malformed — blocking, not probing." >&2
      # → [BLOCKED]: skip the probe entirely.
    else
      case "$RESOLVED" in
        cr|bugbot|greptile) CB_REVIEWER="$RESOLVED" ;;
        *) CB_REVIEWER="" ;;   # `unknown` and anything else → omit the flag
      esac

      # Reached ONLY when the resolution above did not block. `|| CB_EXIT=$?`,
      # not a bare assignment: exit 1 is the EXPECTED pre-tick result here, and
      # under `set -e` a bare assignment would abort the block before the status
      # was ever captured.
      CB_EXIT=0
      if [[ -n "$CB_REVIEWER" ]]; then
        CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM" --reviewer "$CB_REVIEWER") || CB_EXIT=$?
      else
        CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM") || CB_EXIT=$?
      fi
    fi
    ```

    An omitted `--reviewer` is safe **only** on the non-blocking branch, where
    `reviewer-of.sh` returned a usable answer that simply was not one of the
    three enum values (`unknown` — no bot has reviewed yet). It is never a
    substitute for a resolution that failed.

    Read the JSON, never `$?` after a pipe. `CLEAN_BEHIND` was already cleared at
    Step 8 entry, so only the two clean outcomes below can raise it:

    - `0` (`safe_to_offer: true`) → `[ACTION]` — **verified clean `BEHIND`.** No snapshot, no rebase, no force-push. Set `CLEAN_BEHIND=1` and continue to **Step 9**: this path is **AC-first**, Step 9a finishes the verification, and Step 10 hands the merge to `/wrap`.
    - `1` whose `reasons_not_safe` / `residual_blockers` are **only** the unchecked-Test-Plan-checkbox count and/or a sole `ac-gate` check-run — **failing *or* still incomplete** — → `[ACTION]` — **clean-`BEHIND` candidate**, i.e. "waiting on Step 9", not a blocker. `clean-behind-check.sh` counts unticked boxes as `reasons_not_safe`, so a pre-tick exit `1` is bookkeeping rather than a real blocker. Treat exactly as `0`: set `CLEAN_BEHIND=1`, continue to Step 9.
    - `1` with **any other** residual blocker → genuinely non-clean `BEHIND`. Surface `reasons_not_safe`, then `[ACTION]` — `diff-survival-check.sh snapshot`, rebase onto base, then `diff-survival-check.sh verify` (Step 1 branch table) and force-push **only** on exit 0; wait for a fresh review, then re-run the gate.
    - `2`/`3`/`4` → `[BLOCKED]` — usage error / PR not found or not open / `gh`-network-jq error. Surface the JSON or stderr. Nothing was reported *about this `BEHIND`*, so it is neither clean nor unclean — **never** read a non-`1` failure as a rebase signal, which would buy a rebase on evidence you do not have.

    `churn.advisory` is context, never a gate.
  - **"CI has N failing check-run(s)"** or **"CI has N incomplete check-run(s)"**: fix CI or wait for incomplete runs, then re-run the gate — **except when the BEHIND bullet above already claimed this pass.** The ordinary pre-tick candidate is a `missing[]` of exactly `BEHIND` + a sole failing-or-incomplete `ac-gate`, so both bullets match the same JSON; the BEHIND bullet wins and this one is `[SKIP]`ped for that `ac-gate` entry. Following this bullet instead would re-enter Step 8 after Step 9's body PATCH, and that read returns `merge_state: "UNKNOWN"` with the `BEHIND` entry **gone from `missing[]`** — so the probe never fires, `CLEAN_BEHIND` stays `0`, Step 9a `[SKIP]`s, and the clean-`BEHIND` path is lost silently. Precedence, concretely: if `missing[]` contains a `BEHIND` entry, resolve the BEHIND bullet first and act on its verdict; only CI entries **other than** that sole pre-tick `ac-gate` (or any CI entry on a pass with no `BEHIND`) belong to this bullet.
- `3` → `[BLOCKED]` — PR not found (closed or merged).
- `2`/`4` → `[BLOCKED]` — script or gh error; surface the message to the user.

---

## Step 9: Verify acceptance criteria

Run the acceptance criteria check via the shared helper:

```bash
ITEMS=$("$AC_CHECKBOXES_SH" "$PR_NUM" --extract)
AC_EXIT=$?
```

Branch on exit code:
- `0` → `$ITEMS` is a JSON array of `{index, checked, text}`. For each item with `checked == false`, read the relevant source files and verify the criterion. Tick passing items by index with `"$AC_CHECKBOXES_SH" "$PR_NUM" --tick "0,2,3"` (or `--all-pass` if every unchecked item passed). On a clean-`BEHIND` candidate (`CLEAN_BEHIND=1`), establish `TICK_AT` **on every path through this step, including the one where nothing needs ticking** — Step 9a item 1 compares it against the `ac-gate` run's `started_at`, and an unset baseline makes that comparison meaningless. A candidate can arrive here already fully ticked (Step 8 admits a `missing[]` of `BEHIND` + a sole `ac-gate` with every box already checked), in which case the tick command never runs:

  ```bash
  if [[ -n "$TICKED_ANY" ]]; then
    # A --tick/--all-pass actually ran: the body reached its final state now.
    TICK_AT=$(date -u +%FT%TZ)
  else
    # Nothing to tick — the body was already final before this step. Use the
    # PR's updatedAt as a conservative upper bound on the last body write: a
    # body edit always bumps it, so a run started after it definitely read the
    # final body. (Other events bump it too, which only makes the baseline
    # later — erring toward "pre-tick suspect", the safe direction.)
    TICK_AT=$(gh pr view "$PR_NUM" --json updatedAt --jq .updatedAt)
  fi
  ```

  If neither can be established, do **not** guess: treat every failing `ac-gate` as pre-tick-suspect and take item 1's single-rerun path, which is bounded and cannot loop.
- `1` → `[BLOCKED]` — PR body is missing a Test Plan section. Every PR must include one (per CLAUDE.md). The PR is NOT merge-ready until the body is fixed — report this to the user and do not continue to the merge decision.
- `3` → `[BLOCKED]` — PR not found.
- `2`/`4` → `[BLOCKED]` — script or gh error; surface stderr to user.

- If all items pass after ticking: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.

---

## Step 9a: Clean-`BEHIND` follow-through (candidates only)

`[SKIP]` unless Step 8 set `CLEAN_BEHIND=1`. Ticking AC has two after-effects; both must settle before Step 10, and they overlap, so run them in this order and wait once. Mirrors `.claude/agents/phase-c-merger.md` Step 2a (issue #1563).

1. **Re-run the `ac-gate` check — but only if it is terminal and failing.** `ac-gate.yml` triggers on `opened`/`synchronize`/`reopened`, so a PR-body edit never re-fires it — a red `ac-gate` on an unticked PR is by design and stays red until rerun. Read the `ac-gate` check-run's **current** status on HEAD first and branch on it; `merge-gate.sh` reports only *failing* checks in `ci_status.blocking[]`, so an absent id means "not failing", never "green":
   - **`completed` + failing** → rerun it. The id in `ci_status.blocking[].id` is a **job** id: `gh run rerun --job "$AC_GATE_JOB_ID"`. A rejected rerun (stale id, permissions, GitHub error) means `ac-gate` was never re-fired, so waiting would burn the whole deadline for nothing → `[BLOCKED]`, reporting the `gh` error and the job id, without entering the wait. The rerun publishes a **new** job id on the same run, so poll that one (or re-read the check-run by name from the HEAD SHA); the old id stays `failure` forever, so polling it would never terminate.
   - **`queued` / `in_progress`** (the Step 8 candidate shape admits this) → **do not rerun *yet*.** GitHub rejects a rerun of a run that is still going, and an in-flight job only publishes another id to chase. But do **not** record this run as authoritative either: by this step's own premise it was fired by the last `synchronize`, i.e. **before** Step 9's tick, and whether its body read lands before or after the PATCH is a race. So wait it out under item 2's deadline, then judge it by **when it started, not by its conclusion** — compare the check-run's `started_at` against `TICK_AT`, the body's final-state baseline that Step 9 establishes on every path (post-`--tick`/`--all-pass` clock reading, or the PR's `updatedAt` when nothing needed ticking):
     - `started_at` **after** `TICK_AT` → the run definitively read the ticked body; its conclusion is authoritative (green → item 2's mergeability wait; failing → a real AC failure, back to Step 9).
     - `started_at` **at or before** `TICK_AT` → pre-tick-suspect. A green conclusion is still trustworthy (it passed on a body that was *less* complete). A **failing** one is not evidence of anything — it is the by-design pre-tick red — so once the run is terminal, rerun it **once** via the `completed` + failing branch above and wait again on the new job id. One rerun only: a second failing conclusion from a run started after `TICK_AT` is a real AC failure.
   - **`completed` + green** → nothing to rerun, but do **not** skip item 2: the body PATCH still invalidated mergeability, and that has to settle before the re-probe.
2. **Wait out the mergeability recompute.** `ac-checkboxes.sh --tick` / `--all-pass` PATCHes the PR body, and GitHub invalidates mergeability on any body write — the next gate read returns `merge_state: "UNKNOWN"` with the `BEHIND` entry **gone from `missing[]`**. That is not a new blocker and never a reason to rebase. Proceed only when **both** hold: the `ac-gate` check-run on HEAD has reached a terminal `status: "completed"` (any conclusion), **and** `gh pr view "$PR_NUM" --json mergeStateStatus` is no longer `UNKNOWN` (~30–60s). Advancing on mergeability alone hands item 3 a still-queued `ac-gate`, which `clean-behind-check.sh` reports as an *incomplete*-CI residual — read as a non-clean `BEHIND`, that triggers exactly the rebase this path exists to prevent. **Both waits share one 10-minute deadline, started on entry to this item** — `WAIT_UNTIL=$(( $(date -u +%s) + 600 ))` as the first thing item 2 does. Anchoring it to "the rerun" would leave two of item 1's three branches with no clock at all (`queued`/`in_progress` and `completed` + green both arrive here having reran nothing), so the wait would either have no bound or compare against an unset value and `[BLOCKED]` on its first tick. Item 1's single rerun, when it fires, **restarts** the deadline from that moment — a fresh job id is fresh work, and it must not inherit time already spent waiting on the run it replaced. The deadline is a stop condition, never a licence to proceed with a condition unmet. Either still unmet at the deadline → `[BLOCKED]`, naming which one did not settle plus the job's URL and status: do **not** re-probe and do **not** rebase — an unsettled wait is not evidence the `BEHIND` is unclean. An `ac-gate` that completes with a **failing** conclusion is a real AC failure → back to Step 9, not a rerun loop — but only once item 1 has established the run actually started **after** `TICK_AT`. A failing conclusion from a pre-tick run is the by-design red, not an AC failure; item 1 sends that one back for its single rerun instead.
3. **Re-probe.** Run `clean-behind-check.sh` again — same invocation *and the same exit-code table* as Step 8, so `2`/`3`/`4` block here too rather than being read as an unclean `BEHIND`. Exit `0` / `safe_to_offer: true` is the authorization Step 10 carries. A still-**incomplete** `ac-gate` in `residual_blockers` here means item 2's wait was left early — go back and finish it. Exit `1` once AC is ticked and `ac-gate` has completed **green** → the `BEHIND` genuinely is not clean: take the Step 8 non-clean rebase path.

---

## Step 10: Report completion

Output a summary:

```
=== /go-on complete ===

Stoppage: <pause | end | token_exhaustion | unplanned> (recorded <record_at>)
Branch: $BRANCH
PR: #$PR_NUM
Reviewer: CR / Greptile
Merge gate: MET / MET (clean BEHIND — cleared by /wrap Step 2.4) / NOT MET
Acceptance criteria: ALL PASSED / N FAILED
Refill: <still paused — clear with /go-on --resume-refill | cleared via <command> --resume-refill | not paused>
Status: Ready for wrap
```

A delegated lane (`pause` / `end`) reports the companion command's own board instead of this block, plus the `Stoppage:` and `Refill:` lines. Ranks 4 and unclassifiable report only what was found — no board, no status line, no state change.

If the merge gate is met and all AC pass, run `/wrap` immediately — no pre-merge prompt (`CLAUDE.md` "PR MERGE AUTHORIZATION"). Honor an explicit user opt-out ("don't merge" / "wait for my approval") if given in chat.

**A verified clean `BEHIND` counts as met for this hand-off (issue #1564).** `BEHIND` is cleared *by* the merge, so on that path the gate still reports exit `1` with the `BEHIND` entry present — the same loop-exit rule `/wrap` applies to itself (gate exit `1` with `BEHIND` as the sole `missing[]` item; issue #1425). When Step 9a's re-probe returned exit `0`, dispatch `/wrap` on that basis rather than reporting NOT MET. **`/wrap` Step 2.4 is the merge executor** — it runs `admin-merge.sh "$PR_NUM" --auto-plain --ac-verified` itself, with no `AskUserQuestion` (issue #754): the plain shape modifies no branch protection, so it needs no user turn. **Do not run `admin-merge.sh` from `/go-on`** — `--auto-plain` carries a repeat guard, so a call here would consume the one attempt and `/wrap`'s would then refuse with exit `8`, merging nothing. Step 2.4 owns that script's semantics; its exits map as: `0` → merged, relay the `AUTO_PLAIN_MERGED` evidence block; `8` → the shape needs a protection change (or an auto attempt already ran) → **surface `/admin-merge $PR_NUM` as a user choice and never auto-run it**; `1` → the clean state no longer held at merge time (main advanced) → Step 2.4's own rebase fall-through and recovery loop.
