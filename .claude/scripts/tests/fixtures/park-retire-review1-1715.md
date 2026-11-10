# Published PR2050 R1 fences — installed-helper and stopped-wake recovery counterfactuals.

<!-- test-anchor: pause-resume-retire-limit-park -->

```bash
LIMIT_WAKE_RESOLVED=false
# ONE read of the park record, bound before anything below acts on it (#1663).
# The compare-and-set that retires the record is pinned to THIS snapshot, so a
# claim landing afterwards loses the compare instead of being erased by it.
# Three separate --get calls could not do that: token and cause would come from
# different instants, and an anchor picked from one could name a record the
# other never saw — the same one-read discipline the leave-time CAS below keeps.
PARK_READ_RC=0
PARK_IDENTITY_READ=false
PARK_DAY_EXPECT=null
LIMIT_TASK_ID=""
PARKED_UNTIL=""
PARK_KIND=""
PARK_RECORD_PRESENT=false
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  PARK_SNAPSHOT=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) \
    || PARK_READ_RC=$?
  if [[ "$PARK_READ_RC" -eq 3 ]]; then
    PARK_IDENTITY_READ=true          # no state file has ever been written: no park to guard
  elif [[ "$PARK_READ_RC" -eq 0 ]] \
    && PARK_DAY_EXPECT=$(printf '%s' "$PARK_SNAPSHOT" | jq -c '
if (. == null or type == "object") and
  (.park_generation == null or
   ((.park_generation | type) == "string" and (.park_generation | length) > 0 and .park_generation != "null"))
then . else error("invalid durable park identity") end
' 2>/dev/null) \
    && LIMIT_TASK_ID=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.limit_resume_task_id // ""' 2>/dev/null) \
    && PARKED_UNTIL=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.parked_until // ""' 2>/dev/null) \
    && PARK_KIND=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.limit_kind // ""' 2>/dev/null) \
    && PARK_RECORD_PRESENT=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '
         [.limit_resume_task_id, .limit_resume_generation,
          .limit_probe_fires_remaining, .limit_cause, .limit_kind,
          .park_claim_token, .park_generation, .parked_until]
         | any(. != null) | tostring' 2>/dev/null); then
    PARK_IDENTITY_READ=true
  elif [[ "$PARK_READ_RC" -eq 0 ]]; then
    PARK_READ_RC=4                   # the record exists but does not parse: unreadable
  fi
fi
# Retiring the park is one atomic write (#1595), now compare-and-set on the identity
# the snapshot observed (#1663). This is the resume path, so the park is over:
# leaving `limit_cause`/`limit_probe_fires_remaining` behind is what makes
# /pm 2D.1(b+) and 2D.5 stay parked *regardless of parked_until* and stop recovery
# before 2D.2's init write ever clears it.
#
# Every new claim has a durable park_generation that survives completion. The
# full original day snapshot compares it AND the absence of a legacy generation:
# a legacy reader cannot erase a newly generated replacement with the same cause.
# Token/cause/bound still identify legacy records, including #1595 no-identity
# records; they clear only while their exact observed snapshot remains current.
# Unknown metadata is retained, and any changed snapshot loses without writes.
#
# Exit contract: 0 cleared · 7 superseded (a newer park owns the slot; nothing was
# written, so its bound, kind and wake identity are untouched) · 8 identity
# unreadable, fail closed · anything else a write error. Composition is #1445: the
# --cas gates the whole batch, so a lost compare writes none of the --set clears.
PARK_RETIRE_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-retire.sh}" "${HOME:+$HOME/.claude/scripts/park-retire.sh}" ".claude/scripts/park-retire.sh"; do
  if [ -x "$candidate" ]; then PARK_RETIRE_SH="$candidate"; break; fi
done
retire_limit_park() {
  [[ "$PARK_IDENTITY_READ" == true ]] || return 8
  [[ -n "$PARK_RETIRE_SH" ]] || return 4
  "$PARK_RETIRE_SH" --repo "$REPO_KEY" --snapshot "$PARK_DAY_EXPECT" \
    --state-helper "$SESSION_STATE_SH"
}

```

<!-- test-anchor: pause-resume-limit-wake-disarm -->

```bash
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  # Every value below comes from the ONE snapshot above — the wake id included
  # (#1663). Re-reading the id here would stop the wake of whatever park holds the
  # slot at that instant, while the CAS refuses to clear the record the snapshot
  # saw: a newer park with its Monitor killed and its record intact, which is the
  # stranded wake this whole single-slot design exists to prevent.
  if [[ "$PARK_READ_RC" -ne 0 && "$PARK_READ_RC" -ne 3 ]]; then
    # Read failure: report degraded state — cannot confirm whether an auto-wake Monitor is armed.
    echo "(DEGRADED: could not read the day park record (rc=$PARK_READ_RC) — recovery remains active)"
  elif [[ "$PARK_READ_RC" -eq 3 ]]; then
    # No state file has ever been written: no wake, and no park to retire.
    LIMIT_WAKE_RESOLVED=true
  elif [[ -n "$LIMIT_TASK_ID" && "$LIMIT_TASK_ID" != "null" ]]; then
    # Only act when the field is readable and non-null
    # Stop the auto-wake before we re-arm day mode below; a successful stop clears the fields.
    if TaskStop "$LIMIT_TASK_ID" 2>/dev/null; then
      # The stop stays FIRST and the retire second (#1663): a claim landing in
      # between armed its own, differently-named wake, so the ID stopped here and
      # the ID left running are distinct — and the CAS below refuses to clear the
      # record that new wake belongs to.
      RETIRE_RC=0
      retire_limit_park || RETIRE_RC=$?
      case "$RETIRE_RC" in
        0)
          LIMIT_WAKE_RESOLVED=true
          echo "(disarmed usage-limit auto-wake $LIMIT_TASK_ID)"
          ;;
        7)
          # Superseded: a newer park owns the slot and armed its own wake. Nothing
          # was written; leave its bound, kind and wake identity alone.
          LIMIT_WAKE_RESOLVED=true
          echo "(stopped usage-limit auto-wake $LIMIT_TASK_ID; a newer usage-limit park now owns the slot — its own wake is left running and nothing was cleared)"
          ;;
        *)
          echo "(DEGRADED: auto-wake stopped but park retirement could not be confirmed (rc=$RETIRE_RC) — park left standing; retry /pause-resume)"
          ;;
      esac
    else
      echo "(WARNING: could not stop usage-limit auto-wake $LIMIT_TASK_ID — recovery remains active)"
    fi
  else
    # No armed wake, but a park record can still stand: /pause stops the wake and
    # stamps `-1` without clearing the park, and 2D.7's abort/error release can
    # leave the same shape. Retire it here or this resume cannot lift the park it
    # is the documented escape hatch for (#1595). Both values come from the same
    # snapshot as the wake id — an unreadable record already fell into the
    # DEGRADED branch above, which is where the old per-field reads failed closed.
    #
    # The fast path turns on RECORD PRESENCE, never on `parked_until` alone. A bound
    # of null does not mean "no park": /pm 2D.1(b+) and 2D.5 keep the day parked on a
    # `preemptive` cause with a `0`/`-1` bound *regardless of `parked_until`* — the
    # invariant this step opens with — so a present record whose bound happens to be
    # null is exactly a park that must be retired, not one that can be skipped.
    # Reading a null bound as absence marked the resume resolved while leaving that
    # cause and bound standing, which is the #1595 deadlock wearing a success message.
    # Only a genuinely empty slot short-circuits; every present record goes through
    # the kind check and `retire_limit_park` below.
    if [[ "$PARK_RECORD_PRESENT" != true ]]; then
      LIMIT_WAKE_RESOLVED=true          # nothing armed and no park recorded
    else
      # Only a rolling-window park may be retired here. A weekly-cap park never
      # arms a wake, so it reaches this branch too — but it is not the `-1`
      # deadlock this clause exists for, and the account is still capped until
      # the window reopens. Lifting it would let the day loop re-arm into a cap
      # that is genuinely still in force, which is why /pm sends weekly parks to
      # manual resume in the first place. Unreadable kind fails closed the same
      # way (#1595).
      if [[ -n "$PARK_KIND" && "$PARK_KIND" != "null" && "$PARK_KIND" != "rolling_window" ]]; then
        # A genuine weekly cap. Every *complete* park writes limit_kind in the
        # same atomic write as parked_until, so a NON-NULL kind that is not
        # rolling_window is a real weekly park and must outlast this resume.
        echo "(usage-limit park left standing: limit_kind=$PARK_KIND is not rolling_window — resume when the window reopens)"
      else
        # rolling_window, or a NULL kind. Null is not a weekly cap: it is 2D.7's
        # incomplete claim — Step 1 writes parked_until and the `-1` sentinel,
        # and limit_kind only arrives with Step 3 — which is precisely the
        # half-written park this retirement exists to clear. Reading null as
        # weekly would strand the one shape the escape hatch is for (#1595).
        RETIRE_RC=0
        retire_limit_park || RETIRE_RC=$?
        case "$RETIRE_RC" in
          0)
            LIMIT_WAKE_RESOLVED=true
            echo "(cleared standing usage-limit park)"
            ;;
          7)
            # Superseded: a park claimed the slot after this step read it. It owns
            # its own bound and wake; clearing it here would orphan both (#1663).
            LIMIT_WAKE_RESOLVED=true
            echo "(standing park left as found: a newer usage-limit park now owns the slot — nothing was cleared)"
            ;;
          *)
            echo "(DEGRADED: standing park record could not be cleared (rc=$RETIRE_RC) — recovery remains active)"
            ;;
        esac
      fi
    fi
  fi
fi
```
