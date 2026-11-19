---
name: go-on
description: Use when stopped work should be picked back up, whatever stopped it — `/pause`, `/end`, a token-exhaustion handoff, an account usage-limit park, a session that died (crash, compaction, sign-out), or a stalled review/merge workflow. Universal resume — classifies the stoppage from the evidence. Invoke as `/go-on [--resume-refill] [--again] [--generation <id>]`.
triggers:
  - go-on
  - resume
  - pick up where we left off
  - continue the interrupted work
  - what was I doing
argument-hint: "[--resume-options [--target LAUNCHER] | --resume-batch --target LAUNCHER | [--resume-refill] [--again] [--generation <id>]] (refill stays paused without --resume-refill)"
---

Resume the work, whatever stopped it. Step 0 classifies the stoppage from recorded evidence and routes; Steps 0b–10 are the interrupted-review-workflow lane it routes to.

## Owner-approved Claude resume batch

For exactly `--resume-batch --target LAUNCHER`, resolve only the trusted
installed helper below. Do not combine the batch with a refill, pause, or
review-resume flag. Run `preview` first. Show every session and original folder,
the exact target launcher, and the terminal destination. If no verified batch
is available, offer the existing manual roster and return.

Use AskUserQuestion to offer **Open this exact batch** or **Cancel**. If that
tool is unavailable, ask in chat and wait for the owner to answer. No approval
is implied by invoking this route or by a quota notice, previous approval,
timeout, ambiguous reply, or cancellation. Never approve on the owner's
behalf. After the fresh explicit approval, pass the exact preview's approval
value and unchanged target to the same helper. A changed or expired preview
requires fresh approval; do not retry an uncertain dispatch.

<!-- test-anchor: go-on-approved-quota-batch -->

```bash
quota_resume_batch_route() {
  local mode="${1:-}" target="${2:-}" approval="${3:-}" candidate
  [[ -n "${HOME:-}" && "$target" =~ ^claude-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 2
  case "$mode" in
    preview) [[ -z "$approval" ]] || return 2 ;;
    approve) [[ "$approval" =~ ^[0-9]{1,12}\.[a-f0-9]{64}$ ]] || return 2 ;;
    *) return 2 ;;
  esac
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/quota-resume-batch.sh}" \
    "${HOME:+$HOME/.claude/scripts/quota-resume-batch.sh}"; do
    [[ -x "$candidate" ]] || continue
    if [[ "$mode" == preview ]]; then
      "$candidate" preview --target "$target"
    else
      "$candidate" approve --target "$target" --approval "$approval"
    fi
    return
  done
  return 1
}
quota_resume_batch_route "${QUOTA_RESUME_BATCH_MODE:-}" "${QUOTA_RESUME_TARGET:-}" "${QUOTA_RESUME_BATCH_APPROVAL:-}"
```

Bind the mode and target from this invocation and the approval value from
the exact preview only after the owner approves. Bind the approval empty
during preview; never trust an inherited value. Report dispatch acceptance,
uncertainty and refusal separately. An accepted dispatch does not prove
Claude has finished opening. Return here without clearing either gate or
running any other recovery action.

## Read-only Claude resume options

For `--resume-options` alone or with `--target <launcher>`, use only a trusted installed
`quota-resume-roster.sh` from the skills worktree or installed scripts directory.
Never fall back to the current checkout or PATH: the helper reads account-wide
local state and runs adjacent installed helpers.

<!-- test-anchor: go-on-quota-resume-options -->

```bash
quota_resume_options() {
  local candidate target="${1:-}"
  [[ -n "${HOME:-}" ]] || return 1
  [[ -z "$target" || "$target" =~ ^claude-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/quota-resume-roster.sh}" \
    "${HOME:+$HOME/.claude/scripts/quota-resume-roster.sh}"; do
    if [[ -x "$candidate" ]]; then
      if [[ -n "$target" ]]; then "$candidate" list --target "$target"; else "$candidate" list; fi
      return
    fi
  done
  return 1
}
quota_resume_options "${QUOTA_RESUME_TARGET:-}"
```

For a targeted invocation, bind `QUOTA_RESUME_TARGET` to the one literal
registered launcher token from the argument before calling the block. For
an untargeted invocation bind it empty. Reject a missing target or extra flags
before invoking any helper; do not interpret `--target` as a resume command.
If the owner requested a target launcher, mention the separate
/go-on --resume-batch --target route as an option for verified /end stops.
Do not run that route from this read-only list.

Show its entries for the current registered Claude account: session ID, folder,
account, summary, and manual resume options. Show each verified path in
`handoffs` once, including handoffs from parked PRs that share a worktree.
When a handoff has `cwd_available: false`, show its path and say its worktree
is unavailable. Show a `not portable` option with its handoff path and never
infer a command from a different record. State the returned
close-original-session precondition before any commands.
Distinguish an unavailable park lookup or unreadable record from an empty list.
If the helper cannot run, say the roster is unavailable. Do not guess a
launcher or read credentials. Return here: do not classify, resume, clear a
gate, or launch anything. Do not combine this flag with any resume flag.

Beside the manual commands, show the returned `launcher_prerequisite`,
including its installed setup command. The owner runs setup and uses the
source line it prints; the roster never creates or sources launchers.

<!-- go-on-routing:begin -->
## Status lines

These apply to Step 0 and to every module the lane reads.
<!-- go-on-routing:end -->

**Output a status line at each step** so the user can follow along:
- `[DONE]` — step already completed, moving on
- `[ACTION]` — step incomplete, executing now
- `[BLOCKED]` — step cannot proceed, reporting why
- `[SKIP]` — step not applicable

---

## Step 0: Classify the stoppage (universal resume)

Every stoppage leaves evidence. Read it, decide which class this is, and continue from the right place — the user never names the stoppage class. `/pause-resume` and `/end-resume` keep working and still own their restores; this step **routes into them** rather than reimplementing them (the "delegation, not reimplementation" rule in `/pause-resume` §Safety).

Evidence sources, the precedence table, the newest-wins tie-break, and the degradation contract: `.claude/reference/universal-resume.md`.

**Direct Form A chip recovery.** When the recorded resume context identifies this launch's own issue and assigned worktree, recover its holder with `chip-claim-receipt.sh read WORKTREE OWNER/REPO ISSUE` and confirm it with `issue-claim.sh ISSUE --renew --holder HOLDER --repo OWNER/REPO` before resuming issue work. Resolve both helpers in the portable order below. Stop on missing or ambiguous launch context, a missing receipt, or failed renewal. A receipt alone cannot identify this launch; never search other worktrees, copy a GitHub marker, or acquire a fresh claim during recovery. The chip's original instructions also apply if resuming without `/go-on`.

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
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}"; do
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

Also read this session's own gate: `/end` uses the native UUID when available;
older stop records and `/pause` use the original session key. Only the
marker and resume receipt use the sanitized key. Either gate key reporting
`active` is enough to hold launches. A failed or invalid read is
`unreadable` unless another key proves an active gate.

<!-- test-anchor: go-on-live-native-session-gate -->

```bash
GATE_LIVE=unreadable
if [[ -n "$EXECUTION_PAUSE_SH" ]]; then
  GATE_LIVE=inactive
  NATIVE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  LEGACY_GATE_SESSION_ID="${CLAUDE_SESSION_ID:-default}"
  if [[ ! "$NATIVE_SESSION_ID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ || "$NATIVE_SESSION_ID" == "$LEGACY_GATE_SESSION_ID" ]]; then
    NATIVE_SESSION_ID=""
  fi
  for GATE_SESSION_ID in "$NATIVE_SESSION_ID" "$LEGACY_GATE_SESSION_ID"; do
    [[ -n "$GATE_SESSION_ID" ]] || continue
    gate_status=$("$EXECUTION_PAUSE_SH" --status --session "$GATE_SESSION_ID" 2>/dev/null) || gate_status=unreadable
    case "$gate_status" in
      active) GATE_LIVE=active; break ;;
      inactive) ;;
      *) GATE_LIVE=unreadable ;;
    esac
  done
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
# `null` — the literal jq text for "this slot holds nothing" — is the ONLY
# absent value, and because the slots are read with `--get-json` (issue #1629)
# that text is unambiguously JSON null: a slot corrupted into the STRING "null"
# arrives quoted as `"null"`, so `parse` yields a string and `slot_class` names
# it `unreadable` instead of reading it as "nothing parked". Raw `--get` printed
# the same four characters for both and could not express the difference.
# An EMPTY string is likewise not absent: every successful `--get-json` read
# prints some JSON, so nothing at all is a damaged read, and it must survive to
# `parse` and classify `unreadable` rather than being coerced here (issue #1611).
PAUSES_RAW="null"
LEGACY_PAUSE_RAW="null"
LEGACY_SUSPEND_RAW="null"
# The names of the slots that could not be read or would not parse. Empty means
# every slot was readable; a name here is reported and that slot alone dropped.
PAUSE_SLOTS_UNREADABLE=""
if [[ -z "$SESSION_STATE_SH" || -z "$REPO_KEY" ]]; then
  # No helper or no repo identity reaches none of them — that is three unreadable
  # slots, not an absent probe.
  PAUSE_SLOTS_UNREADABLE="pauses pause suspend"
else
  for PAUSE_SLOT in pauses pause suspend; do
    # --get-json keeps each slot's JSON type on the wire (issue #1629); exit
    # codes are identical to --get, so the rc mapping below is unchanged.
    SLOT_RAW=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].$PAUSE_SLOT" 2>/dev/null)
    SLOT_RC=$?
    if (( SLOT_RC == 3 )); then SLOT_RAW="null"   # no state file — the absence probe A already saw
    elif (( SLOT_RC != 0 )); then
      # Named here, so hand the combine `null` and let it stay silent about this
      # slot — otherwise it would classify the empty read `unreadable` too and
      # name the same slot twice.
      SLOT_RAW="null"
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
  --arg keyed  "$PAUSES_RAW" \
  --arg lpause "$LEGACY_PAUSE_RAW" \
  --arg lsusp  "$LEGACY_SUSPEND_RAW" '
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
  # A value that will not parse is a DAMAGED slot — caught HERE, inside the slot,
  # so it classifies as `unreadable` rather than aborting the program and taking
  # the other two with it. The caught value is a string, which slot_class already
  # calls unreadable. Because the caller reads with `--get-json` (issue #1629),
  # a slot holding the JSON string `"null"` arrives quoted and parses to a
  # STRING — unreadable, named — while a genuinely absent slot arrives as bare
  # `null` and parses to JSON null. A slot holding `""` arrives as `""` and
  # parses to the empty string: also unreadable. An EMPTY read parses no better
  # than any other non-JSON text and is damaged for the same reason, so
  # special-casing `""` to null would report exactly that corrupt slot as
  # "nothing parked" (issue #1611). Only the caller's literal `null` — a
  # genuinely absent slot, or one already named above — is absent.
  def parse: try fromjson catch "unparseable";
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

### 0.5a Log the stoppage (ranks 2–4 only; issue #2292)

<!-- go-on-routing:begin -->
For ranks 1–4, run the lane preflight in [module routing](#module-routing) before this step.
<!-- go-on-routing:end -->

A stop nobody planned is written down once, to the desk's private database, so the causes can be counted later. **Never** for rank 1 (`pause` / `end` are planned stops) or rank 5. Never posted to GitHub or written to a repository file. This step records and never blocks: any failure here is one line, then dispatch continues.

Resolve the desk CLI from installed locations only (`~/.claude/skills-worktree/desk/bin/human-queue.sh`, then `~/.claude/desk/bin/human-queue.sh`); unresolved → one `DEGRADED: human-queue.sh not found — stoppage log unavailable, continuing without it` line.

- **Cause:** rank 2 → `usage_limit`; rank 3 → `token_exhaustion`; rank 4 → `crash` when probe E found a registry entry still `running`/`stopping`/`stop_failed` (a task that never closed, so the session died), else `unknown`.
- **Thread:** the dead session's id when the stale registry entry names one (`session_id`), else this session's.
- **Stop time:** the record's own time (`record_at`, the handoff's time, or the registry entry's `updated_at`) as UTC `Z`; when none is known use now and say so in the evidence.
- **Evidence:** one fixed line — class, probe letters, and the PR or branch — never transcript text.
- **An entry the dead session's own Stop hook already wrote** (`stoppage why --thread <id>` shows `still stopped`) is not duplicated: record nothing; it is closed after dispatch (below).

```bash
# STOP_CAUSE, STOP_THREAD, STOP_AT (UTC Z), STOP_REF (issue#N|pr#N, may be empty),
# STOP_EVIDENCE are set from the bullets above; HQ_CLI is the resolved CLI.
if [[ -n "${HQ_CLI:-}" ]]; then
  if ! "$HQ_CLI" stoppage why --thread "$STOP_THREAD" 2>/dev/null | grep -q 'still stopped'; then
    STOP_ARGS=(--thread "$STOP_THREAD" --repo "${REPO_KEY:-unknown}" --cause "$STOP_CAUSE" \
      --evidence "$STOP_EVIDENCE" --at "$STOP_AT" --source go-on)
    [[ -n "${STOP_REF:-}" ]] && STOP_ARGS+=(--ref "$STOP_REF")
    "$HQ_CLI" stoppage record "${STOP_ARGS[@]}" >/dev/null 2>&1 || true
  fi
fi
```

**Close it only when work actually resumed.** The idle time ends when dispatch relaunches or continues work, not when `/go-on` merely ran. After a dispatch that did so (a delegated resume that re-armed work, relaunched pipelines, or entered Steps 0b–10), run the block below. When dispatch launched nothing (a usage-limit park whose window is still shut, an unreadable inventory that blocked ranks 3 and 4), leave the entry open: a later `/go-on` finds it `still stopped` and closes it then.

```bash
if [[ -n "${HQ_CLI:-}" ]]; then
  # The marker goes only when `resume` succeeded (closed, or kept locally to be
  # sent in order). A failed resume leaves it, so a later prompt retries.
  if "$HQ_CLI" stoppage resume --thread "$STOP_THREAD" >/dev/null 2>&1; then
    rm -f "${HOME:-/nonexistent}/.claude/desk-stoppages/open/$STOP_THREAD" 2>/dev/null || true
  fi
fi
```

An unreachable database keeps both operations locally and sends them later, in order (`desk/docs/stoppages.md`).

### 0.6 Dispatch

**PM run mode reread (before any lane, silent).** Read the mode with the installed `run-mode.sh` only (`$HOME/.claude/skills-worktree/.claude/scripts/run-mode.sh`, then `$HOME/.claude/scripts/run-mode.sh`): `run-mode.sh --repo "$REPO_KEY" get` only when `REPO_KEY` is nonempty. An empty `REPO_KEY` skips the call and uses `default` directly, since an empty `--repo` would resolve an unscoped key. Print nothing on success; a missing helper also reads as `default`. Never take the mode from a stoppage record or a summary (`.claude/reference/run-modes.md`).

For ranks 2–4, run 0.5a first (it records the stoppage and never blocks the dispatch below), and close the entry after a dispatch that actually resumed work.

**Never duplicate a live task or Monitor.** Before any lane, list live registry entries (`"$TASK_REGISTRY_SH" --list --live`) and read `.prs["<N>"].babysit.active`. Work already covered by a live identity is reported, not relaunched; the delegated commands take the locked `stopped -> rearming` claim that makes concurrent resumes single-writer.

An unresolved `background-task-registry.sh` or a failed listing is an **unreadable inventory, never an empty one** (the same rule `/pause` Step 0 applies): say the live-task check could not run, and do not launch anything in the `unplanned` or `token_exhaustion` lanes on the assumption nothing is running. Delegation to `/pause-resume` / `/end-resume` still proceeds — their own claims are locked, so they cannot double-launch on a blind check.

<!-- go-on-routing:begin -->
Each lane's procedure is a module, read only when its class is selected. Use the [module routing](#module-routing) section to resolve them.

| Class (0.4) | Kind module | Review modules the lane can reach |
|---|---|---|
| `pause` / `end` | `kind:planned-stop` | None |
| `usage_limit_park` | `kind:usage-limit-park` | None |
| `token_exhaustion` | `kind:token-exhaustion` | `review:prepare` first, then the module holding the step its `needs` names, then onward in order |
| `unplanned` | `kind:unplanned` | `review:prepare`, `review:publish`, `review:respond`, `review:merge`, in order |
| `none`, or unclassifiable | None | None: report from Step 0 and read no module |

<!-- go-on-routing:end -->

- **Monitors and artifact watches that died with the session are not re-armed here.** They belong to their owning skills' recovery paths (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`, `monitor-mode.md` §PM Monitoring Recovery) — the same ones `/pause-resume` Step 5 delegates to. Name what was found and which command owns it.

---

<!-- go-on-routing:begin -->
## Module routing

The entry holds the classifier and every gate that must always hold. A lane's procedure loads only after Step 0 selects it. There are no `@` imports. Resolve the dispatcher once at the first lane that needs a module and reuse the path for this invocation. Classification, rank 5, and an unclassifiable report need no dispatcher.

<!-- test-anchor: go-on-module-resolver -->
```bash
GO_ON_MODULE_DISPATCH=""
for candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/skills/go-on/scripts/dispatch-module.sh}" \
  "${HOME:+$HOME/.claude/skills/go-on/scripts/dispatch-module.sh}" \
  ".claude/skills/go-on/scripts/dispatch-module.sh"; do
  if [[ -x "$candidate" ]]; then
    GO_ON_MODULE_DISPATCH="$candidate"
    break
  fi
done
```

Call `"$GO_ON_MODULE_DISPATCH" OPERATION PHASE` and read only its returned path. The operations are `kind` (`planned-stop`, `usage-limit-park`, `token-exhaustion`, `unplanned`) and `review` (`prepare`, `publish`, `respond`, `merge`).

**Preflight before any write.** After 0.5 finds no matching receipt (or `--again` was passed), and before 0.5a, the receipt write, or any delegation, launch or other side effect, call the dispatcher for every module the selected lane can reach: the kind module, plus all four review modules for `unplanned`, and for `token_exhaustion` `review:prepare` plus every review module from the one holding the step its `needs` names onward (Step 6 or Step 7: `review:respond` and `review:merge`; Step 1b: all four). Keep the returned paths. The preflight checks that each module is present and reads none of them. Then read the kind module. Read a review module only when the lane reaches it. Reuse a module already read in this valid context.

**A missing module is a recoverable blocker.** An unresolved dispatcher, or exit 2 or 3 from it, stops the lane. Never fall back to another module, to a remembered older version, or to a copy in a different checkout. Print `[BLOCKED] /go-on module unavailable: <operation:phase>` with the dispatcher's message, then the class, repository, PR or issue, evidence digest (0.5), last completed step, and next step. Write no receipt. When the preflight failed, nothing was written, so the next step is: restore the skill install, then rerun `/go-on`. When a module disappears after the receipt was written, the next step is: restore it, then rerun `/go-on --again`.

**Compaction or restart.** Reload this entry and re-run the 0.2a generation check and the live-work check. Keep the class Step 0 already selected; a fresh `/go-on` invocation applies the full 0.4 precedence table again. The receipt this invocation wrote marks the dispatch as done, so continue the active lane rather than dispatching again. For `pause` / `end` and `usage_limit_park`, read only the active kind module. For `token_exhaustion` and `unplanned`, read only the active kind module, `review:prepare`, and the active review module. Reading `review:prepare` again does not re-run its completed steps: it re-resolves the lifecycle helpers, and before any write re-check Step 0b's authorship guard and Step 1's diff-survival guard. Each step's own `[DONE]` check then decides where to resume. Variables a step set before the compaction are gone, so a lane resuming in `review:merge` always re-runs Step 8 (read-only) before Step 9a or Step 10: that re-derives `CLEAN_BEHIND` from the current evaluation instead of letting Step 9a skip its clean-`BEHIND` follow-through. Never repeat a commit, push, reply, thread resolution or delegation that current evidence (HEAD, PR state, threads, the delegate's state) shows complete.
<!-- go-on-routing:end -->
