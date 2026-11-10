# Published pre-1715 retirement fences

Actual prior source retained only as the ABA negative control.

<!-- test-anchor: old-retire -->

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
PARK_TOKEN_EXPECT=null
PARK_CAUSE_EXPECT=null
PARK_UNTIL_EXPECT=null
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
    && PARK_TOKEN_EXPECT=$(printf '%s' "$PARK_SNAPSHOT" | jq -c '.park_claim_token // null' 2>/dev/null) \
    && PARK_CAUSE_EXPECT=$(printf '%s' "$PARK_SNAPSHOT" | jq -c '.limit_cause // null' 2>/dev/null) \
    && PARK_UNTIL_EXPECT=$(printf '%s' "$PARK_SNAPSHOT" | jq -c '.parked_until // null' 2>/dev/null) \
    && LIMIT_TASK_ID=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.limit_resume_task_id // ""' 2>/dev/null) \
    && PARKED_UNTIL=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.parked_until // ""' 2>/dev/null) \
    && PARK_KIND=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '.limit_kind // ""' 2>/dev/null) \
    && PARK_RECORD_PRESENT=$(printf '%s' "$PARK_SNAPSHOT" | jq -r '
         [.limit_resume_task_id, .limit_resume_generation,
          .limit_probe_fires_remaining, .limit_cause, .limit_kind,
          .park_claim_token, .parked_until]
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
# Anchor precedence — token, then cause, then bound:
#   * `park_claim_token` non-null: a 2D.7 claim is mid-assembly. The token is unique
#     per claim, so it is the strongest identity available — stronger than the cause,
#     which is a two-valued enum two different parks can share.
#   * else `limit_cause` non-null: a completed record. Coarser than the token by
#     construction; the residual it leaves is named in the reference contract.
#   * else `parked_until` at the value just read (null included): the no-identity
#     record. It still clears — that is the #1595 manual-resume escape hatch, which a
#     guard that refused a no-identity record would deadlock shut — and `parked_until`
#     is the one field EVERY claim shape writes, so the clear is refused only when the
#     slot has actually changed hands, never on the record this step read.
#
# Exit contract: 0 cleared · 7 superseded (a newer park owns the slot; nothing was
# written, so its bound, kind and wake identity are untouched) · 8 identity
# unreadable, fail closed · anything else a write error. Composition is #1445: the
# --cas gates the whole batch, so a lost compare writes none of the --set clears.
retire_limit_park() {
  local anchor_path anchor_expect field rc=0
  local -a clears=()
  # Fail closed: an unreadable identity can hide a live park, exactly as the
  # parked_until and limit_kind reads below fail closed (#1595).
  [[ "$PARK_IDENTITY_READ" == true ]] || return 8
  if [[ "$PARK_TOKEN_EXPECT" != null ]]; then
    anchor_path=".repos[\"$REPO_KEY\"].day.park_claim_token"; anchor_expect="$PARK_TOKEN_EXPECT"
  elif [[ "$PARK_CAUSE_EXPECT" != null ]]; then
    anchor_path=".repos[\"$REPO_KEY\"].day.limit_cause";      anchor_expect="$PARK_CAUSE_EXPECT"
  else
    anchor_path=".repos[\"$REPO_KEY\"].day.parked_until";     anchor_expect="$PARK_UNTIL_EXPECT"
  fi
  # Every field still clears; the anchor is dropped from the --set list because the
  # CAS target already writes it null. All of them are SIBLINGS under `.day` — a --set
  # naming a strict ancestor of the CAS path is a usage error (exit 2), not a write.
  for field in limit_resume_task_id limit_resume_generation limit_probe_fires_remaining \
               limit_cause limit_kind park_claim_token parked_until; do
    [[ ".repos[\"$REPO_KEY\"].day.$field" == "$anchor_path" ]] && continue
    clears+=(--set ".repos[\"$REPO_KEY\"].day.$field=null")
  done
  "$SESSION_STATE_SH" --cas "$anchor_path=null" --expect "$anchor_expect" \
    "${clears[@]}" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 6 ]]; then   # lock timeout — retry once, as the leave-time CAS does
    rc=0
    "$SESSION_STATE_SH" --cas "$anchor_path=null" --expect "$anchor_expect" \
      "${clears[@]}" >/dev/null 2>&1 || rc=$?
  fi
  return "$rc"
}
```

<!-- test-anchor: old-d5 -->

```bash
# ONE read, bound: the anchor and the verdict must come from the same instant, or
# the CAS pins to a record this step never saw.
D5_SNAPSHOT_RC=0
D5_SNAPSHOT=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) \
  || D5_SNAPSHOT_RC=$?
D5_CLEAR_RC=0
if [[ "$D5_SNAPSHOT_RC" -ne 0 && "$D5_SNAPSHOT_RC" -ne 3 ]]; then
  D5_CLEAR_RC=8                      # unreadable identity: fail closed, clear nothing
else
  [[ "$D5_SNAPSHOT_RC" -eq 3 ]] && D5_SNAPSHOT='{}'
  D5_TOKEN_EXPECT=$(printf '%s' "$D5_SNAPSHOT" | jq -c '.park_claim_token // null' 2>/dev/null) || D5_CLEAR_RC=8
  D5_CAUSE_EXPECT=$(printf '%s' "$D5_SNAPSHOT" | jq -c '.limit_cause // null' 2>/dev/null)      || D5_CLEAR_RC=8
  D5_UNTIL_EXPECT=$(printf '%s' "$D5_SNAPSHOT" | jq -c '.parked_until // null' 2>/dev/null)     || D5_CLEAR_RC=8
fi
if [[ "$D5_CLEAR_RC" -eq 0 ]]; then
  # Anchor precedence — token (a mid-assembly 2D.7 claim, the strongest identity
  # because it is unique per claim), then limit_cause (a completed record), then
  # parked_until at the value just read, null included (the no-identity record —
  # and, here, the empty slot a fresh 2D.7 claim would take).
  if [[ "$D5_TOKEN_EXPECT" != null ]]; then
    D5_ANCHOR=".repos[\"$REPO_KEY\"].day.park_claim_token"; D5_EXPECT="$D5_TOKEN_EXPECT"
  elif [[ "$D5_CAUSE_EXPECT" != null ]]; then
    D5_ANCHOR=".repos[\"$REPO_KEY\"].day.limit_cause";      D5_EXPECT="$D5_CAUSE_EXPECT"
  else
    D5_ANCHOR=".repos[\"$REPO_KEY\"].day.parked_until";     D5_EXPECT="$D5_UNTIL_EXPECT"
  fi
  D5_CLEARS=()
  for D5_FIELD in limit_resume_task_id limit_resume_generation limit_probe_fires_remaining \
                  limit_cause limit_kind park_claim_token parked_until; do
    [[ ".repos[\"$REPO_KEY\"].day.$D5_FIELD" == "$D5_ANCHOR" ]] && continue
    D5_CLEARS+=(--set ".repos[\"$REPO_KEY\"].day.$D5_FIELD=null")
  done
  # The thrash counter rides the same atomic batch (#1445): a superseded compare must
  # leave it alone too, or a brand-new park would resume with its hit count reset.
  "$SESSION_STATE_SH" --cas "$D5_ANCHOR=null" --expect "$D5_EXPECT" \
    "${D5_CLEARS[@]}" --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=0" \
    >/dev/null 2>&1 || D5_CLEAR_RC=$?
  if [[ "$D5_CLEAR_RC" -eq 6 ]]; then   # lock timeout — retry once, then judge
    D5_CLEAR_RC=0
    "$SESSION_STATE_SH" --cas "$D5_ANCHOR=null" --expect "$D5_EXPECT" \
      "${D5_CLEARS[@]}" --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=0" \
      >/dev/null 2>&1 || D5_CLEAR_RC=$?
  fi
fi
case "$D5_CLEAR_RC" in
  0) echo "RESUME_CLEAR=cleared" ;;
  7) echo "RESUME_CLEAR=superseded" ;;   # a newer park owns the slot — nothing written
  *) echo "RESUME_CLEAR=error rc=$D5_CLEAR_RC" ;;
esac
```
