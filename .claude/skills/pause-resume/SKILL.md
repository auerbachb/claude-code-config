---
name: pause-resume
description: Resume companion to /pause; `/go-on` is the primary resume entry point and routes here. Explicitly clears the background-launch gate, reads parked and stopped-task recovery state, prints the current board, and re-arms selected work without duplicating live tasks. The refill gate is cleared only with --resume-refill. Triggers on "pause-resume", "resume from pause", "back from laptop", "restore parked work", "what did I park".
triggers:
  - pause-resume
  - resume from pause
  - back from laptop
  - restore parked work
  - what did I park
argument-hint: "[--resume-refill] (--resume-refill clears the refill pause; without it the pause stands and is reported)"
---

Thin restorer for `/pause`. Reads the pause state, prints the board as it is **now** (not as it was parked — it re-reads GitHub before printing), re-arms what was stopped, and reports what is waiting on you.

> **`/go-on` is the primary entry point for resuming.** It classifies the stoppage from recorded evidence and routes here when the newest record is a `/pause`, forwarding `--resume-refill` verbatim — so nobody has to remember which stop happened (Issue #1397; ladder: `.claude/reference/universal-resume.md`). This command keeps working unchanged and stays the direct path when you already know the work was paused; it remains the executor, and `/go-on` never reimplements the restore below.

Running this when no pause state exists is a clean no-op: `No parked session found — nothing to resume.`

## Step 0: Resolve helpers

`/pause-resume` is invocable from any thread — including one whose cwd is a different worktree than the one `/pause` ran in. The three-candidate resolution order is identical to every other stop-style command:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || SESSION_STATE_SH=""
EXECUTION_PAUSE_SH=$(resolve_script execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_script background-task-registry.sh) || TASK_REGISTRY_SH=""
```

The current checkout is intentionally not a fallback: this resume command may
run from an unrelated or untrusted repository, and must execute only installed
helpers.

An unresolved `session-state.sh` in this skill is fatal for the state-read path but recoverable: fall back to the marker file in Step 1. Say which path is being used so the user knows.

Parse `--resume-refill` and the internal auto-wake generation token:

```bash
RESUME_REFILL=false
CALLER_GENERATION=""
EXPLICIT_MARKER=""
_NEXT_IS_GENERATION=false
_NEXT_IS_MARKER=false
for arg in $ARGUMENTS; do
  if [[ "$_NEXT_IS_GENERATION" == true ]]; then
    CALLER_GENERATION="$arg"
    _NEXT_IS_GENERATION=false
    continue
  fi
  if [[ "$_NEXT_IS_MARKER" == true ]]; then
    EXPLICIT_MARKER="$arg"
    _NEXT_IS_MARKER=false
    continue
  fi
  case "$arg" in
    --resume-refill) RESUME_REFILL=true ;;
    --generation) _NEXT_IS_GENERATION=true ;;
    --marker) _NEXT_IS_MARKER=true ;;
  esac
done
[[ "$_NEXT_IS_GENERATION" == false ]] || \
  { echo "ERROR: --generation requires a value." >&2; exit 2; }
[[ "$_NEXT_IS_MARKER" == false ]] || \
  { echo "ERROR: --marker requires a value." >&2; exit 2; }
```

Before clearing any gate, validate a Monitor-supplied generation against the
current saved generation. A stale or unreadable generation terminates without
changing state, so an old wake cannot reopen execution or re-arm work:

```bash
if [[ -n "$CALLER_GENERATION" ]]; then
  [[ -n "$SESSION_STATE_SH" ]] || \
    { echo "Cannot validate auto-wake generation; no gate was cleared." >&2; exit 1; }
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  [[ -n "$REPO_KEY" ]] || \
    { echo "Cannot identify the auto-wake repository; no gate was cleared." >&2; exit 1; }
  STORED_GENERATION=$("$SESSION_STATE_SH" \
    --get ".repos[\"$REPO_KEY\"].day.limit_resume_generation" 2>/dev/null) || \
    { echo "Cannot read the saved auto-wake generation; no gate was cleared." >&2; exit 1; }
  if [[ -z "$STORED_GENERATION" || "$STORED_GENERATION" == "null" || \
        "$CALLER_GENERATION" != "$STORED_GENERATION" ]]; then
    echo "Stale auto-wake rejected; no gate was cleared or work re-armed."
    exit 0
  fi
fi
```

## Step 1: Enumerate every un-resumed pause record

**Selection is a set, not a slot (issue #1576).** Pause records are keyed per
session at `.repos[<key>].pauses[<session-id>]`, so a repo can hold several
un-resumed boards at once — two sessions pausing minutes apart is the ordinary
case, not an error. Read **all** of them, and treat the legacy singleton slots
as members of that same set rather than as an else-branch that fires only when
the map is empty. A sibling record with `active: false` is never proof that
nothing else is parked: that inference is precisely what dropped an earlier
session's board silently.

Order of precedence:

1. **`--marker <path>` short-circuits selection entirely** — an explicitly named
   marker is the user overriding discovery, so it is honoured before any state
   read. It is the only way to reach a marker `/pause` published as not
   auto-discoverable (`_unknown` repo key).
2. **The union of state records** — every `active != false` entry in
   `.pauses[*]`, plus the legacy singleton `.pause` and `.suspend` blocks when
   they are themselves un-resumed. Newest first by `paused_at` (legacy
   `suspended_at`).
3. **The marker glob** — only when the union held **no records at all**. An
   empty *selection* is not the same as an empty *union*: records that exist and
   are all already resumed are a finished repo, and markers are retained after a
   restore, so globbing there would rediscover a completed board and restore it
   twice. `RECORDS_TOTAL` keeps the two cases apart.

**Three sources, three verdicts (issue #1611).** `.pauses`, the legacy `.pause`,
and the legacy `.suspend` are validated **each on its own** before they are
combined, by one `slot_class` rule shared verbatim with `/go-on` probe B and
`candidate-ownership.sh`. A damaged slot is named individually and drops out
alone; the surviving slots still contribute their records. The keyed map takes
that same rule as the singletons — a corrupt map is *named*, never silently
empty. Nothing raises: aborting the combine over one bad slot is what discarded
the healthy boards read beside it.

```bash
PAUSE_RECORDS='[]'
RECORDS_TOTAL=0
# Set when ANY pause slot was discarded as damaged — the keyed map or either
# legacy singleton (issue #1611). RECORDS_TOTAL counts only the slots that were
# read, so it cannot by itself distinguish "no records existed" from "records
# existed and we threw that slot away" — and only the first of those may reach
# the marker glob.
PAUSES_DISCARDED=false
USE_MARKER=false
MARKER_PATH=""
STATE_KEY="pause"
STATE_UNREADABLE=false
# jq refuses an empty --argjson; normalize an absent read to null. A slot that
# READ successfully but holds text that is not JSON is a DAMAGED slot, not an
# absent one — passing it as a JSON STRING keeps it that way, because a string is
# neither a record nor a map and `slot_class` classifies it `unreadable`.
# Coercing it to `null` here would read a corrupt board as "nothing parked".
# The literal `null` is the ONLY absent value, and since the slots are read with
# `--get-json` (issue #1629) that text is unambiguously JSON null: a slot
# corrupted into the STRING "null" arrives quoted as `"null"`, parses as a JSON
# string, and is named `unreadable` instead of being read as absent — which is
# precisely what raw `--get` could not express. An EMPTY argument is likewise NOT
# absent: every successful `--get-json` read prints something, so nothing at all
# means the read produced nothing, which is damaged; it falls through to the
# parse check below and reaches `slot_class` as a string (issue #1611).
# `_read_slot` hands this the literal `null` for the genuinely-absent and
# already-named cases.
_json_or_null() {
  [[ "$1" != "null" ]] || { printf 'null'; return; }
  if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then printf '%s' "$1"
  else jq -Rn --arg v "$1" '$v'; fi
}
# "Could not look" is never "nothing there". Exit 3 is the one unambiguous
# absent — no state file has ever been written; every other non-zero is an
# UNREADABLE source, which must be carried into the verdict rather than
# collapsed into the same "" an absent path produces.
# Sets SLOT_VALUE rather than printing: a `$(...)` capture runs the function in
# a SUBSHELL, where the STATE_UNREADABLE it sets would be discarded along with
# it — an unreadable state file would then degrade to a silent "nothing parked",
# which is the single failure this degradation contract exists to prevent.
SLOT_VALUE=""
_read_slot() { # _read_slot <jq-path> <label> -> SLOT_VALUE
  local _rc=0
  SLOT_VALUE=""
  # `--get-json`, not `--get`: raw output collapses an absent slot, a stored
  # JSON null, and a slot corrupted into the string "null" into the same four
  # characters, so the third would be restored-from as "nothing parked"
  # (issue #1629). Exit codes are identical between the two modes, so the rc
  # mapping below is unchanged.
  SLOT_VALUE=$("$SESSION_STATE_SH" --get-json "$1" 2>/dev/null) || _rc=$?
  case "$_rc" in
    # rc=0 keeps the value verbatim, EMPTY INCLUDED: an empty read means the
    # read produced no JSON at all, which is damaged, and the combine must see
    # it (issue #1611).
    0) ;;
    3) SLOT_VALUE="null" ;;      # no state file — genuinely absent
    # Named right here, so hand the combine `null`: were it given the empty read
    # it would classify this slot `unreadable` as well and name it twice.
    *) SLOT_VALUE="null"
       STATE_UNREADABLE=true
       echo "DEGRADED: could not read $2 (session-state.sh rc=$_rc) — parked work there was not consulted" >&2 ;;
  esac
}

# Resolve the repo key even on the --marker path: it is what validates that an
# explicitly named marker belongs to this repo.
REPO_KEY=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
fi

# No explicit marker, and we cannot even address the state: that is an
# unreadable source, not an empty one. Without this the later no-op path would
# print "No parked session found" on a missing helper or an unresolvable repo.
if [[ -z "$EXPLICIT_MARKER" ]] && [[ -z "$SESSION_STATE_SH" || -z "$REPO_KEY" ]]; then
  STATE_UNREADABLE=true
  echo "DEGRADED: ${SESSION_STATE_SH:+repo identity}${SESSION_STATE_SH:-session-state.sh} unresolved — pause records were not consulted" >&2
fi

if [[ -z "$EXPLICIT_MARKER" && -n "$SESSION_STATE_SH" ]]; then
  if [[ -n "$REPO_KEY" ]]; then
    _read_slot ".repos[\"$REPO_KEY\"].pauses" "the pauses map";        PAUSES_MAP="$SLOT_VALUE"
    _read_slot ".repos[\"$REPO_KEY\"].pause" "the legacy pause slot";   LEGACY_PAUSE="$SLOT_VALUE"
    _read_slot ".repos[\"$REPO_KEY\"].suspend" "the legacy suspend slot"; LEGACY_SUSPEND="$SLOT_VALUE"
    # Every slot is validated on its OWN inside the one program below (issue
    # #1611), which returns the surviving records, how many records existed, and
    # the name of each damaged slot. Nothing is pre-checked here and nothing
    # raises: a raise aborts the program, so one corrupt legacy singleton used
    # to empty PAUSE_RECORDS outright and take the healthy keyed boards with it.
    PAUSE_SELECTION=$(jq -nc \
      --arg repo_key "$REPO_KEY" \
      --argjson pauses "$(_json_or_null "$PAUSES_MAP")" \
      --argjson legacy_pause "$(_json_or_null "$LEGACY_PAUSE")" \
      --argjson legacy_suspend "$(_json_or_null "$LEGACY_SUSPEND")" '
      def base: ".repos[" + ($repo_key | tojson) + "]";
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
      # A malformed array must not throw and lose the whole selection.
      def pend($a): ($a | if type == "array"
                          then map(select((type != "object") or ((.rearmed // false) != true))) | length
                          else 0 end);
      # Un-resumed = still active, OR closed but with re-arms outstanding, which
      # is the partially-restored record Step 2 has always retried. A missing or
      # unparseable `active` counts as active.
      # NOT `.active // true`: jq treats false as empty, so that expression
      # returns true for exactly the resumed records it is meant to exclude.
      def unresumed: (.active != false)
                     or ((pend(.monitors_stopped) + pend(.background_tasks_stopped)) > 0);
      # Only a `present` slot contributes entries; a damaged one contributes none
      # and is named through `degraded` instead. Each entry carries its own
      # write-back address, so Step 7 closes exactly the record Step 1 loaded.
      def keyed_entries:
        if slot_class("map") != "present" then []
        else (to_entries
              | map({ session_id: .key,
                      state_key:  "pauses",
                      state_path: (base + ".pauses[" + (.key | tojson) + "]"),
                      record:     .value })) end;
      def legacy_entries($key):
        if slot_class("slot") != "present" then []
        else [{ session_id: (.session_id // "legacy"),
                state_key:  $key,
                state_path: (base + "." + $key),
                record:     . }] end;
      ( ($pauses | keyed_entries)
      + ($legacy_pause | legacy_entries("pause"))
      + ($legacy_suspend | legacy_entries("suspend")) )
      # `total` counts the records that EXISTED, before the un-resumed filter;
      # `records` is the selection, newest first on either spelling of the stamp.
      | { total: length,
          records: ( map(select(.record | unresumed))
                     | sort_by(.record.paused_at // .record.suspended_at // "")
                     | reverse ),
          degraded: ( ($pauses | slot_degraded("the pauses map"; "map"))
                    + ($legacy_pause | slot_degraded("the legacy pause slot"; "slot"))
                    + ($legacy_suspend | slot_degraded("the legacy suspend slot"; "slot")) ) }')
    if [[ -z "$PAUSE_SELECTION" ]]; then
      PAUSE_RECORDS='[]'
      RECORDS_TOTAL=0
      STATE_UNREADABLE=true
      PAUSES_DISCARDED=true
      echo "DEGRADED: pause records could not be combined — none were consulted" >&2
    else
      # One line per damaged slot, naming only that slot. Any slot NOT named here
      # was read and still contributed, so a corrupt `.pause` no longer empties
      # the selection: the keyed boards and the legacy `.suspend` record survive
      # it, and an explicit --marker still recovers on top of that.
      while IFS= read -r _damaged_slot; do
        [[ -n "$_damaged_slot" ]] || continue
        STATE_UNREADABLE=true
        PAUSES_DISCARDED=true
        echo "DEGRADED: $_damaged_slot is not a pause record, or holds a malformed record — its records were not consulted; the other pause slots still were" >&2
      done < <(jq -r '.degraded[]?' <<<"$PAUSE_SELECTION")
      PAUSE_RECORDS=$(jq -c '.records' <<<"$PAUSE_SELECTION")
      # `RECORDS_TOTAL` counts only the slots that were READ, so on its own it
      # cannot tell "no records existed" from "a slot was discarded and its
      # records with it". PAUSES_DISCARDED keeps those two apart — only the first
      # of them may reach the marker glob.
      RECORDS_TOTAL=$(jq -r '.total' <<<"$PAUSE_SELECTION")
    fi
    LEGACY_SELECTED=$(jq -r '[.[] | select(.state_key == "suspend")] | length' <<<"$PAUSE_RECORDS")
    [[ "$LEGACY_SELECTED" -eq 0 ]] || \
      echo "(including legacy pre-Issue-1310 suspend state; new pauses use .pauses[<session>])"
  fi
fi

RECORD_COUNT=$(jq -r 'length' <<<"$PAUSE_RECORDS" 2>/dev/null || echo 0)
[[ "$RECORD_COUNT" -le 1 ]] || \
  echo "Found $RECORD_COUNT un-resumed pause records for $REPO_KEY — restoring each, newest first."

# Records existed and every one of them is already resumed. That is a finished
# repo, not an unreadable one: say so and stop BEFORE the marker glob, which
# would otherwise rediscover the retained marker of a board already restored and
# restore it again. `--marker` never reaches here — it skips the enumeration, so
# RECORDS_TOTAL is 0 and an explicitly named board is always honoured.
if [[ "$RECORD_COUNT" -eq 0 && "$RECORDS_TOTAL" -gt 0 && "$STATE_UNREADABLE" == false ]]; then
  echo "All $RECORDS_TOTAL pause record(s) for $REPO_KEY are already resumed. Run /pause to park a new session."
  exit 0
fi

# Fall back to the newest marker file only when NO record existed to select from.
# Validate the repo key embedded in the filename before using a candidate.
if [[ "$RECORD_COUNT" -eq 0 ]]; then
  if [[ -n "$EXPLICIT_MARKER" ]]; then
    [[ -r "$EXPLICIT_MARKER" ]] || \
      { echo "Explicit pause marker is unreadable: $EXPLICIT_MARKER" >&2; exit 1; }
    case "$(basename "$EXPLICIT_MARKER")" in
      pause-*.md) STATE_KEY="pause" ;;
      suspend-*.md) STATE_KEY="suspend" ;;
      *) echo "Explicit marker is not a pause/suspend recovery artifact." >&2; exit 1 ;;
    esac
    MARKER_REPO=$(sed -n 's/^Repository: `\([^`]*\)`$/\1/p' "$EXPLICIT_MARKER" | head -1)
    if [[ -n "$MARKER_REPO" && "$MARKER_REPO" != "_unknown" && \
          -n "${REPO_KEY:-}" && "$MARKER_REPO" != "$REPO_KEY" ]]; then
      echo "Explicit marker belongs to $MARKER_REPO, not $REPO_KEY." >&2
      exit 1
    fi
    MARKER_PATH="$EXPLICIT_MARKER"
  fi
  if [[ -z "$MARKER_PATH" && -z "${REPO_KEY:-}" && "$STATE_UNREADABLE" == false ]]; then
    # Without a repo key we cannot safely distinguish our own markers from
    # another repo's — the pattern *--* would match anything. Fail closed.
    echo "No parked session found — nothing to resume."
    exit 0
  fi
  # Automatic glob ONLY when the union held no records at all. `RECORD_COUNT`
  # alone is not enough: records that exist but were filtered — all resumed, or
  # dropped because a corrupt slot made that one source unreadable — leave
  # RECORDS_TOTAL positive, and their markers are retained after a restore. A
  # glob there rediscovers a finished board and restores it a second time.
  # An EXPLICIT --marker is unaffected: it skips the enumeration entirely, so
  # RECORDS_TOTAL is 0 and it sets MARKER_PATH above.
  if [[ -z "$MARKER_PATH" && "$RECORDS_TOTAL" -eq 0 && "$PAUSES_DISCARDED" == false ]]; then
    REPO_OWNER="${REPO_KEY%%/*}"
    REPO_NAME="${REPO_KEY#*/}"
    REPO_KEY_SAFE="${#REPO_OWNER}-${REPO_OWNER}-${#REPO_NAME}-${REPO_NAME}"
    LEGACY_REPO_KEY_SAFE="${REPO_KEY//\//-}"
    # New pause markers use an injective filename key and also carry the exact
    # owner/repo in their content. Legacy suspend markers use the old key.
    while IFS= read -r candidate; do
      MARKER_NAME="$(basename "$candidate")"
      MARKER_REPO=$(sed -n 's/^Repository: `\([^`]*\)`$/\1/p' "$candidate" 2>/dev/null | head -1)
      if [[ "$MARKER_NAME" == pause-*"-${REPO_KEY_SAFE}-"* && \
            "$MARKER_REPO" == "$REPO_KEY" ]]; then
        MARKER_PATH="$candidate"
        break
      elif [[ "$MARKER_NAME" == suspend-*"-${LEGACY_REPO_KEY_SAFE}-"* ]]; then
        # Compatibility-only path for markers written before Issue #1310.
        MARKER_PATH="$candidate"
        STATE_KEY="suspend"
        break
      fi
    done < <(ls -t "$HOME/.claude/handoffs/pause-"*.md \
      "$HOME/.claude/handoffs/suspend-"*.md 2>/dev/null)
  fi

  if [[ -n "$MARKER_PATH" ]]; then
    echo "(reading from marker file — session-state.json was not readable; using $MARKER_PATH)"
    USE_MARKER=true
    # The Step 2 loop iterates PAUSE_RECORDS, so the marker board needs an entry
    # or Steps 3-7 never run for it. `state_path` is empty by design: there is no
    # state record to write back to, and Steps 5 and 7 skip their completion
    # writes on an empty path rather than inventing one.
    PAUSE_RECORDS=$(jq -nc --arg sk "$STATE_KEY" --arg mp "$MARKER_PATH" \
      '[{session_id:"marker", state_key:$sk, state_path:"", record:{marker_path:$mp}}]')
    RECORD_COUNT=1
    # Parse key fields from the human-readable marker. The marker's sections
    # mirror the pause state block; extract what is available.
    PAUSE_STATE=$(awk '
      /^##? Landed/        { in_landed=1; in_parked=0; in_monitors=0 }
      /^##? Parked/        { in_parked=1; in_landed=0; in_monitors=0 }
      /^##? Monitors/      { in_monitors=1; in_landed=0; in_parked=0 }
      /^##/                { in_landed=0; in_parked=0; in_monitors=0 }
      { print }
    ' "$MARKER_PATH")
    # The marker is human-readable prose; later steps read it directly via
    # $MARKER_PATH rather than parsing $PAUSE_STATE as JSON.
  fi
fi

# No records AND no marker. Which of the two verdicts applies depends on whether
# any source was UNREADABLE: "nothing is parked" is a claim, and it may only be
# made when every source was actually read.
if [[ "$RECORD_COUNT" -eq 0 && "$USE_MARKER" == false && "$STATE_UNREADABLE" == true ]]; then
  echo "Pause state could not be read and no marker was found — parked work may exist." >&2
  echo "Resolve the state file, or point at a board directly: /pause-resume --marker <path>" >&2
  exit 1
fi
if [[ "$RECORD_COUNT" -eq 0 && "$USE_MARKER" == false ]]; then
  echo "No parked session found — nothing to resume."
  exit 0
fi
```

**Reading from `session-state.json` is the primary path.** When that path is available, all later steps can use `jq` to parse each record as JSON. When the marker fallback is active (`USE_MARKER=true`), later steps read the marker file directly from `$MARKER_PATH` — they cannot assume `$PAUSE_STATE` is valid JSON, and should extract what they can from the human-readable sections.

**`.pauses` is invisible to `--session-view`** (that projection lifts only `.prs` and `.root_repo`). Always read it with an explicit `--get-json .repos["<key>"].pauses` — never via `--session-view`. The same holds for the legacy `.pause` and `.suspend` slots. Use `--get-json`, not `--get`, for every pause slot: raw output cannot tell an absent slot from one holding the JSON string `"null"`, so a corrupt board would read as "nothing parked" (issue #1629).

**Each selection entry carries its own write-back address.** `state_path` is the
exact jq path of the record — `.repos[<key>].pauses[<session>]` for a keyed
record, `.repos[<key>].pause` or `.repos[<key>].suspend` for a legacy one — and
`state_key` names which shape it is. Steps 5 and 7 write through that stored
path rather than re-deriving one, so a legacy restore closes the legacy record
in place and a keyed restore touches only its own session's entry. Rebuilding
the path from `$STATE_KEY` alone cannot address a keyed record, and rebuilding
it from the current session's ID would close the wrong session's board.

The legacy `.pause` / `.suspend` reads and the `suspend-*.md` glob are
compatibility inputs only; new `/pause` runs never write those names. They are
**union members, not a fallback branch**: reading them only when `.pauses` is
empty would make an un-resumed pre-upgrade board unreachable the moment any
session wrote a keyed record — the same masking bug one level up.

New marker auto-discovery requires the exact `Repository: \`owner/repo\`` field;
the injective filename match is an index, not repository-identity authority.
An `_unknown` marker is resumable only through the explicit `--marker` path
printed by `/pause`.

## Step 2: Restore each selected record, newest first

Steps 3–7 form the restore sequence for **one** record. Run them once per entry
in `$PAUSE_RECORDS`, newest first, binding that entry's fields first:

```bash
RESTORED=0
REMAINING='[]'
REFILL_CLEAR_PENDING=false   # repo-wide; Step 6 only marks it, Step 8 writes it
for _i in $(jq -r 'keys_unsorted[]' <<<"$PAUSE_RECORDS"); do
  ENTRY=$(jq -c ".[$_i]" <<<"$PAUSE_RECORDS")
  PAUSE_STATE=$(jq -c '.record'     <<<"$ENTRY")
  STATE_PATH=$( jq -r '.state_path' <<<"$ENTRY")
  STATE_KEY=$(  jq -r '.state_key'  <<<"$ENTRY")
  RECORD_SESSION=$(jq -r '.session_id' <<<"$ENTRY")
  # ... Steps 3-7 for this record ...
done
```

**The verdict below is per record, never per repo.** A record that is fully
resumed is skipped and the loop continues to the next one; it is never read as
"this repo has nothing parked". That inference is the bug this command was
rebuilt to remove — a sibling session's resumed record used to end the whole
command, leaving another session's board parked with no error printed anywhere.

**A record that fails mid-restore does not abort the others.** Report it, add it
to `REMAINING`, and carry on to the next record; Step 8 names everything left.

For a JSON state read, check the record's `active` flag. For a marker-only read, the marker's existence implies an incomplete restore (a fully-resumed session writes `active: false` in the state file, which masks the state before this step runs):

```bash
if [[ "$USE_MARKER" == false ]]; then
  # `.active // true` would answer "true" for a resumed record — jq's // treats
  # false as empty — so the idempotent guard below would never fire. Compare
  # against false explicitly; anything else, missing included, is active.
  ACTIVE=$(jq -r 'if .active == false then "false" else "true" end' \
    <<<"$PAUSE_STATE" 2>/dev/null || echo "true")
  if [[ "$ACTIVE" == "false" ]]; then
    # Check whether any re-arms were incomplete (added in Step 7)
    if ! PENDING_REARMS=$(jq -er '
      ((.monitors_stopped // [])
        | map(select((.rearmed // false) != true))
        | length)
      + ((.background_tasks_stopped // [])
        | map(select((.rearmed // false) != true))
        | length)
    ' <<<"$PAUSE_STATE" 2>/dev/null); then
      echo "Pause recovery state is unreadable; keeping the session active." >&2
      PENDING_REARMS=-1
    fi
    if [[ "$PENDING_REARMS" -lt 0 ]]; then
      # Unreadable, not empty: leave this record alone and report it, but keep
      # restoring the other sessions' boards.
      REMAINING=$(jq -c --argjson e "$ENTRY" '. + [$e]' <<<"$REMAINING")
      continue
    fi
    if [[ "$PENDING_REARMS" -gt 0 ]]; then
      echo "Record $RECORD_SESSION was partially resumed ($PENDING_REARMS re-arm(s) still pending). Continuing restore..."
    else
      echo "Record $RECORD_SESSION is already marked resumed (active: false) — skipping."
      continue
    fi
  fi
fi
```

Idempotent on a fully-resumed record. On a partially-resumed record (some re-arms failed), the step continues so Step 5 can retry the incomplete entries. `continue` — never `exit` — is what keeps a skipped or unreadable record from ending the command while another session's board is still parked.

When every selected record is skipped as already resumed, say so once at the
end and name the count, rather than printing the pre-#1576 line that claimed the
whole repo had nothing parked.

## Step 3: Re-read GitHub for each parked PR

Before printing the board, re-read GitHub for each PR listed in this record's `parked` array. A state that moved since pause (a review that landed, a merge that completed after the `/wrap` window, CI that finished) is reported as it is **now**, not as it was parked.

For each parked PR, run `gh pr view <N> --json state,mergeStateStatus,mergeable,reviewDecision` and update the parked entry's display. A PR whose `state: MERGED` is reported as landed (with a note that it merged after the window) rather than parked. A PR whose CI finished running is reported with its updated status.

This re-read is display-only: it does not change the persisted record. The record is a historical record of the parking point.

## Step 4: Print the board

For JSON state, render the timestamp as
`jq -r '.paused_at // .suspended_at // "unknown"'`. The second field is the
legacy pre-Issue-1310 spelling; never print an empty timestamp merely because
the parked session predates the rename.

```
=== Resuming from pause at <paused_at> (window was <window_minutes>m) ===

Landed during pause:
  merged PR #N  (<at>)
  <also merged after window: PR #M — merged after window expiry>
  <nothing landed> if empty

Parked (<N> units) — current state:
  PR #M [<current GitHub state>] — stopped at: <stopped_at> · next: <next_move> · waiting on: <waiting_on>
  Subagent <kind> — handoff at <path>
  <nothing parked> if empty

Monitors to re-arm:
  babysit PR #N — will re-arm via /babysit-pr
  PR fleet monitor — will re-arm via /pr-monitor-and-manage-wake
  Day-mode loop — will re-arm via /pm day resume
  <nothing to re-arm> if all monitors_stopped entries have no stopped entry

Refill pause:
  <REFILL_PAUSED=true: "Refilling is paused (full_stop). To resume: tell Claude 'resume refilling' in this session, or /pause-resume --resume-refill to clear it now.">
  <REFILL_PAUSED=false: "Refilling is not paused.">
```

The parked units show current GitHub state alongside the parking-point snapshot, so the user immediately sees what changed while the session was closed.

## Step 4b: Open the execution gate for recovery

Only after Step 1 found state and Step 2 confirmed recovery is still active,
clear the session execution gate. This ordering keeps a missing or already
resumed pause as a clean no-op that does not mutate the gate. Clear before any
Monitor, Agent, Workflow, or background Bash is re-armed; if clearing fails,
re-arm nothing **for this record** and carry on to the next one:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
# The gate is SESSION-scoped, and this record may belong to ANOTHER session
# (issue #1576). Clearing only the current session leaves the parked session
# launch-blocked after its board was restored, and /go-on probe A keeps reading
# that live gate as a pause. Clear the record's own gate, and this session's as
# well when they differ — an unarmed gate clears as a no-op. `marker` and
# `legacy` are placeholder ids for records that never carried a session, so only
# this session's gate exists to clear for them.
GATE_TARGETS="$SESSION_ID"
case "$RECORD_SESSION" in
  ""|marker|legacy|"$SESSION_ID") : ;;
  *) GATE_TARGETS="$RECORD_SESSION $SESSION_ID" ;;
esac
GATE_CLEARED=true
for GATE_SESSION in $GATE_TARGETS; do
  if [[ -z "$EXECUTION_PAUSE_SH" ]] || \
     ! "$EXECUTION_PAUSE_SH" --clear --session "$GATE_SESSION"; then
    GATE_CLEARED=false
  fi
done
if [[ "$GATE_CLEARED" != true ]]; then
  # `continue`, never `exit`: this block runs inside the Step 2 per-record loop,
  # so exiting here would abandon every later record without re-arming it and
  # without Step 8 ever naming it — the silent whole-command abort this issue
  # removes. Each failed record lands in REMAINING and Step 8 names them all.
  echo "Could not clear the pause execution gate for $RECORD_SESSION; nothing was re-armed for this record." >&2
  REMAINING=$(jq -c --argjson e "$ENTRY" '. + [$e]' <<<"$REMAINING")
  continue
fi
```

## Step 5: Re-arm what was stopped

First inspect current-session stopped registry entries. Re-check runtime state
before every re-arm so an already-running identity is never duplicated. Resume
stopped agents by their exact runtime ID with `SendMessage`; for workflows,
background commands, and Monitors use the recorded recovery path and owning
skill, then mark the old entry `rearmed`. A missing recovery path is reported
as pending, not guessed. Preserve the stopped entry for audit history.

**Re-arm the table-freshness floor when a round resumes.** `/pause` disarms it by DATA (it clears the render record) and the shutdown stops its persistent Monitor — so both halves are gone after a pause. `/subagent` arms that watch **once per session**, on the reasoning that it stays alive for the rest of the round; a resumed round breaks that assumption, and nothing else re-arms it. Left out, the unprompted hourly pulse is simply absent for the remainder of the round: `--check` still answers correctly when a heartbeat asks, but the floor stops volunteering, which is the whole guarantee.

Do this only when a round is actually being resumed (at least one pipeline re-armed above), and only with a resolved repo key:

```bash
# `--repo-key` prints `_unknown` and exits 0 when it cannot resolve a repo, so
# an emptiness test alone never fires — normalise the sentinel first, or the
# watch gets armed on a scope no render will ever write to.
[[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
TABLE_FRESHNESS_SH=$(resolve_script table-freshness.sh) || TABLE_FRESHNESS_SH=""
if [[ -n "$TABLE_FRESHNESS_SH" && -n "$REPO_KEY" ]]; then
  # Record the board this resume just printed (Step 4), then re-arm. Recording
  # first matters: arming over an absent record gives a watch that polls
  # nothing and stays silent forever while looking armed.
  ACTIVE_COUNT=<pipelines re-armed above, running + queued>
  if [[ "${ACTIVE_COUNT:-}" =~ ^[0-9]+$ ]] && (( ACTIVE_COUNT > 0 )); then
    if "$TABLE_FRESHNESS_SH" --note-rendered --active "$ACTIVE_COUNT" \
         --repo "$REPO_KEY" --session "${CLAUDE_SESSION_ID:-default}" \
         --surface pause-resume; then
      # Hand `--arm-command` output to the Monitor tool with persistent: true.
      "$TABLE_FRESHNESS_SH" --arm-command --repo "$REPO_KEY" \
        --session "${CLAUDE_SESSION_ID:-default}"
    else
      echo 'DEGRADED: table-freshness clock not recorded on resume — floor not re-armed; re-render the "Running now" table on every heartbeat'
    fi
  fi
fi
```

Nothing to re-arm (an empty board) correctly leaves the floor disarmed — that is the idle exemption, not a gap.

**Before delegating to any re-arm skill, disarm the usage-limit auto-wake Monitor if one is armed.** This prevents a double resume when the user runs `/pause-resume` manually while a limit-wake Monitor is still ticking (i.e. the rolling-window park from 2D.6 has not yet fired automatically). **One registry covers both wake shapes:** 2D.7's bounded probe Monitor (#1428) records its identity in these same fields, so the block below stops it too. **Retire the whole park record here — never restamp the `-1` sentinel** (#1595): `/pause-resume` *is* the manual resume that `/pm` 2D.1(b+) and 2D.5 name as the only way out of a `-1` park, and both of those branches stay parked on a `preemptive` cause with a `0`/`-1` bound **regardless of `parked_until`**, stopping recovery before 2D.2's init write — the only other place the park is cleared. A sentinel left standing here would leave the escape hatch its own message points at unable to open, so the resume clears `parked_until`, `limit_cause`, `limit_kind` and the bound in one write. `/pause` keeps writing `-1`, and correctly: there the park is meant to stand. When `/pause-resume` is invoked **by the Monitor itself** (not manually), it carries `--generation <id>`; validate the generation before proceeding to reject stale or duplicate wakes:

```bash
LIMIT_WAKE_RESOLVED=false
# Retiring the park is one atomic write (#1595). This is the resume path, so the
# park is over: leaving `limit_cause`/`limit_probe_fires_remaining` behind is what
# makes /pm 2D.1(b+) and 2D.5 stay parked *regardless of parked_until* and stop
# recovery before 2D.2's init write ever clears it.
retire_limit_park() {
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_cause=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=null" \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=null"
}
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  LIMIT_TASK_RC=0
  LIMIT_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_resume_task_id" 2>/dev/null) || LIMIT_TASK_RC=$?
  if [[ "$LIMIT_TASK_RC" -ne 0 && "$LIMIT_TASK_RC" -ne 3 ]]; then
    # Read failure: report degraded state — cannot confirm whether an auto-wake Monitor is armed.
    echo "(DEGRADED: could not read day.limit_resume_task_id (rc=$LIMIT_TASK_RC) — recovery remains active)"
  elif [[ "$LIMIT_TASK_RC" -eq 0 && -n "$LIMIT_TASK_ID" && "$LIMIT_TASK_ID" != "null" ]]; then
    # Only act when the field is readable and non-null
    # Stop the auto-wake before we re-arm day mode below; a successful stop clears the fields.
    if TaskStop "$LIMIT_TASK_ID" 2>/dev/null; then
      if retire_limit_park; then
        LIMIT_WAKE_RESOLVED=true
        echo "(disarmed usage-limit auto-wake $LIMIT_TASK_ID)"
      else
        echo "(DEGRADED: auto-wake stopped but its state could not be cleared — recovery remains active)"
      fi
    else
      echo "(WARNING: could not stop usage-limit auto-wake $LIMIT_TASK_ID — recovery remains active)"
    fi
  elif [[ "$LIMIT_TASK_RC" -eq 3 ]]; then
    # No state file has ever been written: no wake, and no park to retire.
    LIMIT_WAKE_RESOLVED=true
  else
    # No armed wake, but a park record can still stand: /pause stops the wake and
    # stamps `-1` without clearing the park, and 2D.7's abort/error release can
    # leave the same shape. Retire it here or this resume cannot lift the park it
    # is the documented escape hatch for (#1595).
    PARK_RC=0
    PARKED_UNTIL=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.parked_until" 2>/dev/null) || PARK_RC=$?
    if [[ "$PARK_RC" -eq 3 ]] || { [[ "$PARK_RC" -eq 0 ]] && [[ -z "$PARKED_UNTIL" || "$PARKED_UNTIL" == "null" ]]; }; then
      LIMIT_WAKE_RESOLVED=true          # nothing armed and no park recorded
    elif [[ "$PARK_RC" -ne 0 ]]; then
      # Fail closed, exactly as the task-id read above does: an unreadable
      # parked_until can hide a standing park.
      echo "(DEGRADED: could not read day.parked_until (rc=$PARK_RC) — recovery remains active)"
    else
      # Only a rolling-window park may be retired here. A weekly-cap park never
      # arms a wake, so it reaches this branch too — but it is not the `-1`
      # deadlock this clause exists for, and the account is still capped until
      # the window reopens. Lifting it would let the day loop re-arm into a cap
      # that is genuinely still in force, which is why /pm sends weekly parks to
      # manual resume in the first place. Unreadable kind fails closed the same
      # way (#1595).
      KIND_RC=0
      PARK_KIND=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_kind" 2>/dev/null) || KIND_RC=$?
      if [[ "$KIND_RC" -ne 0 && "$KIND_RC" -ne 3 ]]; then
        echo "(DEGRADED: could not read day.limit_kind (rc=$KIND_RC) — park left standing, recovery remains active)"
      elif [[ -n "$PARK_KIND" && "$PARK_KIND" != "null" && "$PARK_KIND" != "rolling_window" ]]; then
        # A genuine weekly cap. Every *complete* park writes limit_kind in the
        # same atomic write as parked_until, so a NON-NULL kind that is not
        # rolling_window is a real weekly park and must outlast this resume.
        echo "(usage-limit park left standing: limit_kind=$PARK_KIND is not rolling_window — resume when the window reopens)"
      elif retire_limit_park; then
        # rolling_window, or a NULL kind. Null is not a weekly cap: it is 2D.7's
        # incomplete claim — Step 1 writes parked_until and the `-1` sentinel,
        # and limit_kind only arrives with Step 3 — which is precisely the
        # half-written park this retirement exists to clear. Reading null as
        # weekly would strand the one shape the escape hatch is for (#1595).
        LIMIT_WAKE_RESOLVED=true
        echo "(cleared standing usage-limit park)"
      else
        echo "(DEGRADED: standing park record could not be cleared — recovery remains active)"
      fi
    fi
  fi
fi
```

**Handle the leave-time wind-down too (issue #1525) — but read before you touch anything.**

**Gate first: `leave.active` must be `true`.** The window is **shared state**: `/pm --window` arms
the same `.repos["<key>"].window` with no `.leave` block at all, and that case is indistinguishable
downstream from "nothing armed". `leave.active != true` (false, null, absent, or unreadable) →
**skip this entire block**: stop nothing, re-arm nothing, leave `.window` exactly as found, and
settle no entry. Without the gate here — ahead of every branch below, not after them — an ordinary
coffee-break `/pause` → `/pause-resume` on a PM planning board would arm a phantom `/leave-by`
check-in and later `/pause` a board that never declared a leave time.

**Then read and validate the deadline, still before stopping anything.** Read
`.repos["$REPO_KEY"].window` **once** (the leave block never carries the deadline — `/leave-by`
Step 5) with Step 11's exit-code table and numeric test, **binding the object** so the retirement
CAS below can pin its write to the exact snapshot the spent-verdict was reached on:

```bash
RESUMED_DEADLINE_RC=0
# ONE read of the shared slot, binding the WHOLE window object — that is what the CAS below
# because --expect is matched at the --cas path and that path is `.window`, not a scalar under
# it — and the verdict is DERIVED from that same object rather than fetched separately, so
# /pm --window cannot swap the window between the judgment and the write.
RESUMED_WINDOW=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].window") || RESUMED_DEADLINE_RC=$?
RESUMED_DEADLINE_EPOCH=$(printf '%s' "$RESUMED_WINDOW" | jq -r '.deadline_epoch // empty' 2>/dev/null)
# The declaration identity, captured with the window: the retirement below guards `.leave` on it,
# the same way /leave-by Steps 8.6, 9 and 11 do. Captured here, before anything is stopped.
RESUMED_DECLARED_AT=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.declared_at" 2>/dev/null) \
  || RESUMED_DECLARED_AT=""
```

**Two reads would make the CAS win against a window this step never judged** — the verdict taken on
the old `deadline_epoch`, the `--expect` holding the object that replaced it. One read, derived and
carried, is what makes exit `7` mean "someone else owns this slot" instead of "you cleared theirs".
 Validating *after* the `TaskStop` is what strands a
declaration: the stop clears the identity pair, the deadline then reads unreadable, and the
inconsistent-record branch preserves `leave.active` while re-arming nothing — an active leave time
with no Monitor and no task ID left to recover it. Read first, and the stop only ever runs on a
branch that knows what it will do next.

**An unreadable or malformed deadline stops here — before the disarm, not after it.** Reading early
is not enough on its own: if the validation fails and the disarm runs anyway, the identity pair is
gone and the inconsistent-record branch below then preserves `leave.active` while re-arming
nothing — an active leave time with no Monitor and no task ID, which is precisely the state that
branch exists to avoid creating. So on any non-numeric, `null`, or unreadable deadline with
`leave.active == true`: report the one-line inconsistent-record verdict, **leave
`winddown_task_id` and `winddown_generation` exactly as found**, stop nothing, and skip the rest of
this block. The live wake stays live and nameable, and `/leave-by` Step 11 can still recover it.

With the gate passed and the deadline read **and validated**, disarm: same shape as the block above,
over `.repos["$REPO_KEY"].leave.winddown_task_id` — read it with its exit code (unreadable → one
`DEGRADED:` line, recovery stays active; null or exit 3 → nothing armed, resolved), **binding the
value** so the release CAS below can name exactly the ID this step was holding:

```bash
# Initialised first: on a SUCCESSFUL read the `||` never fires, so an uninitialised RC would stay
# unbound and every `-ne 0` test on it below would be a syntax error on the empty string.
OLD_WINDDOWN_TASK_RC=0
OLD_WINDDOWN_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.winddown_task_id" 2>/dev/null) \
  || OLD_WINDDOWN_TASK_RC=$?
# The generation this resume is entitled to invalidate — read with the ID, before any write.
OLD_WINDDOWN_GENERATION=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.winddown_generation" 2>/dev/null) \
  || OLD_WINDDOWN_GENERATION=""
```

Then
**invalidate the generation before stopping the task** — the order `/leave-by` Step 9 mandates and
`/pause` Step 2 repeats, for the same reason: a `TaskStop` cannot retract a `--checkin` the Monitor
has already emitted, and a queued one still passes Step 8.1 here, starting a `/pause` inside a
restore that is still running — the very nesting the re-arm branch below refuses to do inline.
Nulling the token first makes every queued event inert whatever the stop then does:

```bash
if [ -n "$OLD_WINDDOWN_GENERATION" ] && [ "$OLD_WINDDOWN_GENERATION" != "null" ]; then
  EXPECT_GEN=$(printf '%s' "$OLD_WINDDOWN_GENERATION" | jq -R .)
else
  EXPECT_GEN=null
fi
INVALIDATE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_generation=null" \
  --expect "$EXPECT_GEN" >/dev/null 2>&1 || INVALIDATE_RC=$?
# retry once on 6 (lock timeout)
```

**Read that exit code, and fail closed — the same contract as `/leave-by` Step 9.** The null
precedes the `TaskStop` only because a queued `--checkin` stays valid until the token is gone, so a
failed write leaves that window open. Stopping the task and continuing anyway would let a queued
event pass Step 8.1 and start a `/pause` inside a restore that is still running — the exact nesting
this ordering exists to prevent. On a non-zero `INVALIDATE_RC` after the retry: stop nothing, clear
nothing, re-arm nothing; report it in one line naming the task ID, and leave `.leave` as found for
`/leave-by` Step 11.

**And invalidate under a CAS, not a blind `--set`** — the same field `/leave-by` Step 6 publishes
and Step 8.5 disarms, both under CAS. `.leave` is repo-scoped state another session can rewrite, so
a re-declaration publishing between the read above and this write would have its token wiped by an
unguarded null, leaving a live Monitor whose `--checkin` fails Step 8.1 (issue #1525).
`INVALIDATE_RC == 7` says exactly that happened *before* this write rather than after: a successor
owns the pair, so stop nothing, release nothing, re-arm nothing, and say nothing about the leave
time — its new owner has its own live Monitor.

Only then `TaskStop` a non-null ID, and on a confirmed stop clear the ID it was holding — **under
the same CAS the unconfirmed path uses**, because a confirmed stop says the *Monitor* is gone, not
that the slot is still this step's to empty:

```bash
RELEASE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null" \
  --expect "$(printf '%s' "$OLD_WINDDOWN_TASK_ID" | jq -R .)" >/dev/null 2>&1 || RELEASE_RC=$?
# retry once on 6 (lock timeout); 7 = replaced, nothing to do
```

**Confirming the stop does not make the write unconditional.** A re-declaration completing during
the `TaskStop` publishes a *new* ID into that slot, and a blind `--set` afterwards discards the only
record of a Monitor that is very much alive — so it can be neither named nor stopped, and its own
`--checkin` later finds a state that no longer matches. Nulling what you no longer hold is the same
mistake in both branches; the two differ only in what they may *claim*, never in how they write.

**On an unconfirmed stop, release the slot anyway — under a CAS, and without claiming the stop.**
The generation is already null, so that Monitor's every event is inert; what the dead ID does still
do is **squat the slot** the re-arm below must win with `--expect null`. Left there, Step 6's CAS
returns `7`, and its exit-7 bullet — written for a *live successor* owning `.leave` — then
`TaskStop`s the Monitor this step just created and leaves the leave time silently un-armed: the old
wake inert, the new one stopped, the check-in never firing (issue #1525). Release exactly what you
hold, never a slot someone else has taken since:

```bash
RELEASE_RC=0
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null" \
  --expect "$(printf '%s' "$OLD_WINDDOWN_TASK_ID" | jq -R .)" >/dev/null 2>&1 || RELEASE_RC=$?
# retry once on 6 (lock timeout); 7 = replaced, nothing to do
```

This releases the slot without asserting the Monitor stopped: **still report the un-stopped task ID**
so a human can end it, and still leave its `monitors_stopped` entry `stopped: false`. Releasing the
slot and claiming the stop are different claims, and only the first is true here.

**`RELEASE_RC` is read on both branches, and a discarded one is a false cleanup record.** `0` means
the slot is empty; `7` means a successor took it, so there is nothing to release and the re-arm
below must not treat the slot as its own. Any other code, after the retry, means **the ID is still
there** — and since the paragraph below hands the un-stopped ID's custody to `monitors_stopped` on
the grounds that the slot was emptied, a swallowed failure makes that handover a lie: the field
still holds an ID that a later `/leave-by` Step 6 publish will collide with at `--expect null`.
Report the release failure in the same line as the stop's own outcome, and do not claim the slot
was cleared.

**Where the un-stopped ID lives after this.** Releasing the slot empties
`leave.winddown_task_id`, so that field is no longer the record of an un-stopped Monitor and no
later branch may claim it is. The durable copy is the `owner: "leave_winddown"` entry in
`monitors_stopped`, which carries the ID alongside `stopped: false` and outlives this step; the
in-memory copy is `OLD_WINDDOWN_TASK_ID`, which is what the report prints. Both branches below that
mention an un-stopped ID mean **those** two, never the released slot.

**Then branch on the deadline, not on the pause** — using the value already read and validated
above:

- **Deadline still in the future** → the leave time **still applies**, and this resume is an
  ordinary mid-afternoon return, not a withdrawal. Keep `leave.active=true`, keep `.window`, and
  **re-arm the wind-down** for the remaining time with a **fresh generation**, publishing the new
  identity pair exactly as `/leave-by` Step 6 does. **Branch on `checkin_epoch` the way Step 11's
  table does, rather than re-arming blindly:** a check-in that already fired leaves `checkin_epoch`
  in the past, and arming a Monitor for a past instant clamps the sleep to one second and winds the
  board down again seconds after the user asked for it back. `checkin_epoch` in the future → re-arm
  for the remaining time. `checkin_epoch` past with the deadline still ahead → the check-in is
  **overdue**, and it is delivered the same way every other check-in is: arm the Monitor with a
  **fresh published generation** and let its sleep clamp to one second, so the check-in arrives as
  its own event once this resume has returned. **Never invoke Step 8 inline from here.** Two
  distinct failures come of that: it nests a `/pause` inside the restore that is still running, and
  Step 8.1 would validate against the generation this step just nulled and exit silently — losing
  the wind-down at the exact moment it was due. The armed-event route has neither problem, because
  Step 6 publishes the generation before arming. Say it in one line:
  `leave time still armed: until 7:00 PM ET · check-in at 6:30 PM ET`. Clearing here instead would
  mean a coffee-break `/pause` at 4 PM silently cancels the 7 PM wind-down the user asked for once
  and never hears about again — the exact promise this feature exists to keep.
- **Deadline confirmed in the past** → the leave time is spent. Retire it per the branches below;
  do not re-arm. Resuming *past* a declared leave time is the user saying it no longer applies, and
  re-arming then would park the board again minutes after they asked for it back.
- **Deadline absent, non-numeric, or unreadable, with `leave.active == true`** → an **inconsistent
  record**, not an expired one — the same verdict `/leave-by` Step 11 reaches on the same evidence.
  Report it in one line, preserve `leave.active` **and** the shared `.window` exactly as found, and
  neither re-arm nor retire. Retiring here would destroy a live deadline on the strength of a lock
  timeout, and the two files must not disagree about what a half-readable record means.

**`leave.active=false` is written on both resolved paths, not only after a `TaskStop`.** The
already-null path is the *normal* one — `/pause` Step 2 stopped the wind-down and nulled the pair
before this ever runs — so clearing only after a stop this step performed would leave the common
case at `active: true` with no Monitor behind it, and `/leave-by` Step 11's recovery would re-arm
the wind-down on the next session start: a leave time the user explicitly resumed past, resurrected
by the resume itself. So:

The `leave.active` gate that admitted this block at all is stated once, at the top — it governs
every branch here, the future-deadline re-arm included, and is not re-derived per branch. Its
load-bearing consequence for *this* path: clearing the window on a null task ID alone would wipe a
PM planning deadline that no leave time ever touched, on every ordinary `/pause` → `/pause-resume`
cycle.

With the gate passed **and the deadline spent**:

- **Null / exit 3 (nothing armed), or a confirmed `TaskStop`** → set
  `leave.active=false` with the (already or newly) null pair **and** clear the armed deadline
  (`.repos["$REPO_KEY"].window=null`) — the latter **under a CAS on the deadline this step read and
  validated**, never blind:

  ```bash
  # RESUMED_DECLARED_AT was captured with RESUMED_WINDOW at the top of this step.
  HOLDER_AT=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.declared_at" 2>/dev/null) || HOLDER_AT=""
  if [ -n "$RESUMED_DECLARED_AT" ] && [ "$HOLDER_AT" = "$RESUMED_DECLARED_AT" ]; then
    # Window first, `.leave` only once its outcome is resolved — /leave-by Step 6,
    # "Only exit 7 is ownership loss". Retry once on 6 (lock timeout) before judging.
    WINDOW_CAS_RC=0
    "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].window=null" \
      --expect "$RESUMED_WINDOW" >/dev/null 2>&1 || WINDOW_CAS_RC=$?
    if [ "$WINDOW_CAS_RC" -eq 0 ] || [ "$WINDOW_CAS_RC" -eq 7 ]; then
      "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].leave.active=false"
    fi   # any other code: retire NOTHING and report the still-armed window
  fi
  ```

  **`.leave` needs the identity guard too, not just `.window` the CAS.** `/leave-by` Steps 8.6, 9
  and 11 all require a matching `declared_at` before touching `.leave`, and this retirement is the
  same claim made from the other side. Without it, a re-declaration landing between this step's
  snapshot and the write is deactivated while its own `.window` survives the CAS — leaving a
  deadline that declines every launch and a Monitor whose `--checkin` exits silently on
  `leave.active`, which is the worst of both records. A mismatch retires nothing.

  `.window` is shared with `/pm` planning deadlines, and this block only ever established that the
  *leave* record is spent. Between the read at the top of this block and the write here, a
  re-declaration or a planning deadline can take the slot; a blind `--set` would then clear a live
  deadline this resume never examined — the same hazard the gate note above raises for the
  null-task-ID path, one step further along. The CAS pins the write to the exact
  `deadline_epoch` the spent-verdict was reached on, and its exit `7` means the window moved on and
  is no longer this step's to clear. **Only that code means so** — a lock timeout or I/O failure
  leaves the spent window armed *and still this resume's*, so retiring `.leave` alongside it would
  produce the one shape `/leave-by` Step 11 reads as normal and passes over in silence, declining
  every launch in the repo thereafter. Hence the order above, and hence the report. Clearing the window is the load-bearing half: a spent
  `deadline_epoch` left behind sits in the past forever, so `/subagent` Step 7's gate would decline
  every pipeline in this repo from here on — the resume would reopen the launch gates and then
  refuse all work through a different one. Mark the `owner: "leave_winddown"` entry in
  `monitors_stopped` `rearmed: true` — for this owner "resolved" means disarmed, not restarted —
  and say it in one line: `leave time cleared — re-declare with /leave-by if it still applies`.
- **An unconfirmed `TaskStop`** → the deadline is still **spent**, so retire it exactly as above —
  `leave.active=false` **and** `.repos["$REPO_KEY"].window=null` — leave the entry `rearmed: false`
  and `stopped: false`, and name the un-stopped ID from `OLD_WINDDOWN_TASK_ID` and the
  `monitors_stopped` entry in the report. **Do not look for it in `leave.winddown_task_id`:** the
  release CAS above already emptied that slot, so treating the field as the surviving record would
  report an un-stopped Monitor as stopped.
  A stop that was not confirmed says nothing about whether the deadline passed, and the two must not
  be conflated: holding `.window` open here re-creates the precise failure the bullet above exists
  to prevent — a past `deadline_epoch` sitting in the past forever while `/subagent` Step 7 declines
  every pipeline in this repo, from a resume that had just reopened the launch gates (issue #1525).
  The Monitor is inert either way (its generation was nulled above), so nothing is left to fire.
  Never claim a Monitor stopped when the stop was not confirmed — retaining and naming the ID is how
  that promise is kept, not by leaving a spent deadline armed.
- **Unreadable** → keep `active=true`, the ID, and `.window` exactly as found, leave the entry
  `rearmed: false`, and report it. Here the deadline genuinely is not known to be spent, so there is
  nothing to retire and no cleared line to print.

For each entry in `monitors_stopped` where `stopped: true` and `rearmed` is not
already `true`, delegate to the appropriate re-arm skill — never reimplement
their logic. Skip entries already confirmed rearmed so retries are idempotent.
Before runtime inspection or delegation, atomically claim the exact task ID in
the shared registry, using the same reservation as `/end-resume`:

```bash
"$TASK_REGISTRY_SH" --transition --session "$SESSION_ID" \
  --task-id "$TASK_ID" --status rearming --from-status stopped
```

Exit 7 means another `/pause-resume` invocation already claimed or completed
the entry; re-read it and do not launch. A missing registry record or task ID
keeps the pause entry pending rather than falling back to an unlocked launch.
After the claim, re-check the execution gate immediately before delegation. A
blocked or failed launch rolls `rearming -> stopped`; a confirmed successor
rolls `rearming -> rearmed`, then (and only then) sets the pause array entry's
`rearmed: true`. The successor registers its own runtime ID through the normal
launch hook. This ordering makes concurrent invocations single-writer even
before either one persists the pause-state array:

- **Babysit watcher for a PR** — invoke `/babysit-pr <PR>` for each entry with `owner: "babysit"`.
- **PR fleet monitor** — invoke `/pr-monitor-and-manage-wake` for any entry with `owner: "pmm"`. The wake companion reads its own saved config (cadence, author, max-parallel, etc.) and re-arms at base cadence.
- **Day-mode loop** — invoke `/pm day resume` for any entry with `owner: "day"`. This re-arms the persistent Monitor and picks up from where the loop paused. After `/pm day` re-arms, it reads the current `day.parked_until`; if the value is still in the future (the limit window has not yet reopened), it will re-arm the auto-wake instead of the tick Monitor — the disarm above ensures only one wake Monitor runs at a time.
- **Usage-limit auto-wake** — entries with `owner: "day_limit_wake"` are
  handled by the disarm block above. Set `rearmed: true` only when
  `LIMIT_WAKE_RESOLVED=true`; otherwise preserve `rearmed: false` and record
  the read, stop, or state-clear error. Never close recovery around an
  unconfirmed disarm.
- **Leave-time wind-down** — entries with `owner: "leave_winddown"` are settled by
  the leave block above, which branches on the **deadline**, not on the pause
  (issue #1525): a deadline still in the future is re-armed with a fresh
  generation and keeps the leave time live; a spent one is disarmed and retired,
  never re-armed, since resuming past a declared leave time is the user
  withdrawing it. Set `rearmed: true` only when the re-arm was published or the
  clear succeeded, and report an unconfirmed disarm exactly as the row above does.

**Relaunch any usage-limit-parked pipelines before finishing (issue #1618).** A registry re-arm restores *live* runtime IDs; a Phase A/B/C pipeline killed by the account wall has no live ID to restore, so it would otherwise stay stopped while everything around it resumed. After the re-arms above, read `.repos["$REPO_KEY"].prs[*]` for entries with `handoff_reason == "usage_limit_park"` and, for each, relaunch that pipeline from its scoped handoff file at the phase `phase_completed` supports — the procedure in `.claude/reference/subagent-thread-limit-park.md` §5, followed **directly**, never by invoking `/go-on` (that command's park lane delegates *here* for the gate, so calling it back would be a cycle). **Claim each PR before you relaunch it.** These records are repo-scoped, not
session-scoped, so two threads resuming the same repo both see the same parked
PRs; without a claim they each relaunch it and the board gets duplicate Phase B
or C pipelines on one branch. Take the same locked single-writer transition this
step already uses for registry entries: under one `session-state.sh` write, flip
that PR's `handoff_reason` from `usage_limit_park` to `usage_limit_relaunching`
and proceed only if the write observed the old value — a PR already reading
`usage_limit_relaunching` belongs to the other thread, so skip it and list it as
claimed elsewhere. A failed or blocked launch rolls the value back to
`usage_limit_park` so the next pass can retry it; only a landed relaunch clears
the field per the rule below. **Reclaim stale claims before you scan.** The
rollback runs in the claiming thread, so a resumer that dies between its claim
and its launch — the account wall closing again, a crash, a session ending —
leaves `usage_limit_relaunching` standing with nothing behind it, and that value
is in neither scan: not this step's (`usage_limit_park` only) and not `/go-on`
Probe F's (the same filter), so the pipeline is stopped, unreachable, and
reported as resumed by the lane that should retry it. So begin the pass by
reading every `usage_limit_relaunching` entry and checking for a live successor
(`background-task-registry.sh --list --live` plus that PR's `babysit.active`,
the same inventory Step 0 reads). One with a live successor belongs to a running
thread — skip it, exactly as a fresh claim does. One with **none** is a dead
claim: flip it back to `usage_limit_park` under the same locked transition and
let this pass claim it normally. An **unreadable** inventory is never an empty
one: leave every claim alone and say the reclaim could not run, rather than
tearing a live thread's claim out from under it. **Every `/subagent` Step 7 launch gate applies to each relaunch** — ceiling, chain head, refill pause, execution pause, and the armed deadline — and a record that fails one is queued with its flag left set, never launched. Clear each PR's `usage_limit_park` and `handoff_reason` only as its relaunch actually lands; a record whose handoff is missing or names a different phase is reported, not relaunched. This is what makes a park adopted from day mode resume correctly: the wake that fires is whichever owner armed it, and both routes end at the same per-PR records.

Entries with `stopped: false` are listed as "not confirmed stopped at pause time — verify manually before re-arming."

If any re-arm delegation fails, report it and carry on — a partial re-arm is better than stopping entirely. **Record a per-entry `rearmed: true/false` field** in the state so Step 7 can set `active=false` only when all required entries are done, and Step 2 can detect a partially-resumed session and retry:

Apply the same filter and bookkeeping to `background_tasks_stopped`, keyed by
exact `task_id`: skip `rearmed: true` entries and process only entries still
requiring restoration. Use the same locked `stopped -> rearming` registry claim
before inspection or launch and the same rollback/finalize transitions. Set
`rearmed: true` only after runtime verification. Set or preserve
`rearmed: false` when recovery failed or required metadata is missing, and add
`resume_error` naming the missing path/action. Persist both updated arrays with
`session-state.sh --set`; never mutate the state file directly.

Write both arrays under **this record's own `$STATE_PATH`**, bound by the Step 2
loop — never a path rebuilt from `$REPO_KEY` and `$STATE_KEY`, which cannot
address a keyed record, and never one built from the *current* session's ID,
which would close a different session's board.

After those writes succeed, re-read that exact path into `PAUSE_STATE`. This
matters for a legacy restore — reading `.pauses[…]` after updating `.suspend`
would evaluate stale or absent arrays — and for a multi-record restore, where
each record must be re-read from its own address. A failed refresh is a partial
restore: keep `active=true`, report the read failure, add the record to
`REMAINING`, and do not run Step 7's completion write for it. Step 7 must
evaluate the freshly persisted arrays, never the pre-rearm snapshot captured at
command start.

## Step 6: Note the refill pause for clearing (--resume-refill only)

`refill` is **repo-wide**, not per record, so the write must not happen here.
Steps 3-7 run once per selected record, and clearing it after the first record
lets the pipeline start new work while sibling boards are still parked — Step 5
may already have re-armed PMM by then. Record the intent inside the loop and
perform the single write in Step 8, once every record has been attempted:

```bash
if [[ "$RESUME_REFILL" == true ]]; then
  REFILL_CLEAR_PENDING=true
fi
```

Without `--resume-refill`, the pause stands and Step 4 has already stated plainly how to lift it.

## Step 7: Mark the pause as resumed

Only set `active=false` after **all** required re-arms in Step 5 have been confirmed (`rearmed: true`). If any required re-arm is still pending, keep `active=true` so the next invocation's Step 2 detects the incomplete restore and retries:

```bash
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  # $STATE_PATH is this record's own address, bound by the Step 2 loop. It is
  # empty on the marker-only path, where there is no state record to close.
  # An empty $STATE_PATH gates the WRITES below — never this whole block, which
  # once left the marker record out of BOTH columns: RESTORED stayed 0 and
  # nothing was added to $REMAINING, so Step 8 reported `Restored 0 of 1` and
  # then named nothing.
  ALL_REARMED=true
  # Check both specialized Monitors and the general stopped-task inventory.
  # An entry with missing recovery metadata remains pending by design.
  PENDING=-1
  if [[ -z "$STATE_PATH" ]]; then
    # MARKER PATH — pending is UNKNOWN here, never zero. The Step 2 loop binds
    # $PAUSE_STATE from the entry's `record`, which on this path is the stub
    # {marker_path}: the marker is human-readable prose and was never parsed into
    # monitors_stopped / background_tasks_stopped. Those absent arrays would
    # compute as 0 pending and report a restore as complete over a board whose
    # Monitors and parked units were never touched — a success claim made
    # exactly when state was unreadable, which is the one situation the marker
    # path exists for. Leave PENDING at -1 so this lands in $REMAINING and
    # Step 8 names it with its marker path.
    echo "Marker restore of $RECORD_SESSION cannot be confirmed: the marker carries no re-arm inventory." >&2
  elif PENDING_RESULT=$(jq -er '
    ((.monitors_stopped // [])
      | map(select((.rearmed // false) != true))
      | length)
    + ((.background_tasks_stopped // [])
      | map(select((.rearmed // false) != true))
      | length)
  ' <<<"$PAUSE_STATE" 2>/dev/null); then
    PENDING="$PENDING_RESULT"
  else
    echo "Recovery state is unreadable; keeping pause active." >&2
  fi
  [[ "$PENDING" -ne 0 ]] && ALL_REARMED=false

  NOW=$(date -u +%FT%TZ)
  # `-n "$STATE_PATH"` is part of the success condition, not just a write guard:
  # a board with no state record to close is never counted as restored.
  if [[ "$ALL_REARMED" == true && -n "$STATE_PATH" ]]; then
    # A failed completion write leaves the record active — correct, and the next
    # invocation re-selects it. What must not happen is counting it as restored
    # or dropping it from the accounting: the board would then be reported as
    # done while its state still says parked.
    if "$SESSION_STATE_SH" \
         --set "$STATE_PATH.active=false" \
         --set "$STATE_PATH.resumed_at=\"$NOW\""; then
      RESTORED=$((RESTORED + 1))
    else
      REMAINING=$(jq -c --argjson e "$ENTRY" '. + [$e]' <<<"$REMAINING")
      echo "Could not close the pause record for $RECORD_SESSION (state write failed) — it stays active." >&2
    fi
  else
    # Keep active=true; update resumed_at to record the attempt. On the
    # marker-only path there is no record to stamp — an empty $STATE_PATH would
    # address the document root, so skip the write and still account for the
    # record below.
    if [[ -n "$STATE_PATH" ]]; then
      "$SESSION_STATE_SH" \
        --set "$STATE_PATH.resumed_at=\"$NOW\""
    fi
    REMAINING=$(jq -c --argjson e "$ENTRY" '. + [$e]' <<<"$REMAINING")
    if [[ -z "$STATE_PATH" ]]; then
      echo "Marker restore of $RECORD_SESSION is unconfirmed: re-arms could not be verified from the marker, so it is not counted as restored. Re-run once the state file is readable, or check the board by hand."
    elif [[ "$PENDING" -lt 0 ]]; then
      echo "Partial restore of $RECORD_SESSION: recovery state could not be verified. Run /pause-resume again to retry."
    else
      echo "Partial restore of $RECORD_SESSION: $PENDING re-arm(s) still pending. Run /pause-resume again to retry."
    fi
  fi
fi
```

The `active=false` write is the idempotent guard from Step 2. The record is kept for history; landed and parked history remains, while both stopped arrays retain their per-entry recovery result.

**Only this record is closed.** `$STATE_PATH` addresses one map entry, and
`--set` preserves its siblings, so closing one session's board leaves every
other un-resumed record exactly as it was — still `active: true`, still selected
by the next Step 1 enumeration.

## Step 8: Account for every selected record

The loop ends here. Nothing may be dropped silently — a record that was skipped,
failed, or was left partially restored is named, with its marker path, so the
user can act on it:

```bash
# The repo-wide refill clear Step 6 deferred, performed ONCE now that every
# record has been attempted — never mid-loop, where it would let new pipeline
# work start while sibling boards were still parked.
if [[ "$REFILL_CLEAR_PENDING" == true && -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].refill={\"paused\":false,\"reason\":null,\"scope\":null,\"at\":null}" \
    && echo "Refill pause cleared — pipeline will refill on the next tick." \
    || echo "Could not clear the refill pause (session-state.sh --set failed) — lift it manually."
fi

LEFT=$(jq -r 'length' <<<"$REMAINING")
echo "Restored $RESTORED of $RECORD_COUNT parked record(s)."
if [[ "$LEFT" -gt 0 ]]; then
  jq -r '.[] | "  still parked: session \(.session_id) — marker: \(.record.marker_path // "none")"' \
    <<<"$REMAINING"
  echo "  Re-run /pause-resume to retry, or /pause-resume --marker <path> for a specific board."
fi
# An unreadable source is reported whatever RECORD_COUNT was. Restoring the
# records that WERE readable is right; reporting success afterwards is not,
# because the boards behind the failed read were never enumerated and the marker
# glob — which only runs when nothing at all was selected — never looked for them.
if [[ "$STATE_UNREADABLE" == true ]]; then
  echo "Some pause sources could not be read; parked work may remain undiscovered." >&2
  echo "  Fix the state file and re-run, or /pause-resume --marker <path> per board." >&2
fi
if [[ "$LEFT" -gt 0 || "$STATE_UNREADABLE" == true ]]; then
  exit 1
fi
```

A record left in `REMAINING` keeps `active: true`, so the next invocation
re-selects it. That is the whole point of per-record accounting: the command may
partially succeed, but it may never report success over a board it did not
restore — or over one it never managed to look for.

## Safety

- **Never auto-clear the refill pause.** It stays paused until the user supplies `--resume-refill` or explicitly says "resume refilling" in chat. A pause that auto-cleared the pause on resume would defeat the purpose of pausing in the first place.
- **Re-read GitHub before printing**, not after. The board should reflect current state, not stale parking-point state, because the user is deciding what to work on next.
- **Fail closed on the no-state check, and distinguish the two closures.** An *absent* record set with no marker is a clean no-op — nothing to resume, exit 0. An *unreadable* source with no marker is not: it exits non-zero naming what could not be read, because "nothing is parked" is a claim that may only be made when every source was actually read. Collapsing a failed read into the same empty value an absent path returns is how a full board reports as no board at all.
- **One record's state is never evidence about another's** (issue #1576). A resumed record, a skipped record, and a record that failed mid-restore each end that record only — never the command. Every `exit` inside the restore sequence is a `continue`, and Step 8 accounts for what is left. The failure this replaces was silent: a sibling's `active: false` ended the whole run, and another session's parked board — stopped Monitors, unlaunched units — was simply never restored, with no error printed anywhere.
- **Delegation, not reimplementation.** The re-arm steps delegate to the existing companion skills (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`) rather than reimplementing their logic. Those skills own their own Monitor-arming contracts and generation tracking; reimplementing them here creates a second code path with a high risk of divergence.
