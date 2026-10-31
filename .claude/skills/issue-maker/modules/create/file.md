# Create: labels and filing

> Load only for: after the draft exists and duplicate screening has cleared
> Prerequisites: create reflection/draft and dedup phase complete

## Step 7: Label suggestion

Suggest labels from the content, but only labels that actually exist in the repo. Prefetch with the same 1000-label bound as `issue-file.sh`, so gh's default first 30 labels cannot prematurely discard valid suggestions. The helper remains the final validator; a prefetch failure is degraded label evidence, never permission to fabricate labels.

```bash
REPO_LABELS=$(gh label list --repo "$REPO" --limit 1000 --json name --jq '.[].name')
```

Keyword → label mapping: `bug`/`fix`/`broken` → `bug`; `feature`/`add`/`new` → `feature`; `refactor`/`clean` → `refactor`; `docs`/`documentation` → `docs`; `skill` → `skill`; `rule` → `rule`. Intersect suggestions with `$REPO_LABELS` and drop any that don't exist.

- **Default mode:** auto-apply the validated suggestions (intersected with `$REPO_LABELS`) and name them in the decision points (Step 9a) — no separate accept prompt.
- **Rapid-fire:** auto-apply the validated suggestions the same way (they just don't get a decision-points line — see the terser report).

Hold the accepted labels one per line in `ACCEPTED_LABELS`; Step 5's create block passes each to `issue-file.sh` as `--label`, and the script re-checks them against the repo (and replaces `ACCEPTED_LABELS` with what it applied).

---

## File only after required gates

Before the create below, confirm reflection and final sizing, dedup disposition, canonical body/footer, title limit, validated labels, and applicable chain cap/links. Resolve `create:postfile` without reading it now; failure blocks creation so recording/reporting cannot be missing after a remote write. Any needed chain modules must likewise have resolved before the first member is filed. Revalidate a changed draft against dedup and sizing rather than trusting a receipt for an older draft.

**Create through `issue-file.sh`** — the one create path `/issue-maker` and the desk's `idea:` intent share (#1766), so the two can never file differently. Before any `gh` call it refuses a title over 70 characters, a body missing one of the seven sections (or with them out of order), and a body whose last line is not the footer — exit 3, nothing sent. It drops labels the repo does not have and the four that hide an issue from `/pm` (`blocked`, `on-hold`, `wontfix`, `duplicate`), never assigns, and prints a URL only for an issue it actually created. `issue-file.sh --template` prints the skeleton above. Write the body to a file with a quoted heredoc so nothing in it expands:

Before running this block, replace `ISSUE_BODY_7f34d1c9` with a newly generated delimiter and verify that it does not occur as a whole line in the finalized body. Keep the delimiter quoted; this makes body content data and prevents delimiter collisions from ending the heredoc early.
<!-- test-anchor: issue-maker-create -->
```bash
# The entry resolved DISPATCHER. Check the post-write dependency before any gh call.
: "${DISPATCHER:?resolve the issue-maker dispatcher before filing}"
bash "$DISPATCHER" create postfile >/dev/null || exit $?
ISSUE_FILE=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/issue-file.sh" \
  "$HOME/.claude/scripts/issue-file.sh" \
  ".claude/scripts/issue-file.sh"; do
  if [ -x "$candidate" ]; then ISSUE_FILE="$candidate"; break; fi
done
# Freeze recording metadata before the remote write; emit it with the result.
: "${ISSUE_TIER:?infer tier before filing}" "${DELIVERS:?record delivered scope before filing}" "${EST_BOUND:?record planning bound before filing}"
RECORD_CHAIN=null
if [ "${IS_INCREMENT:-false}" = true ]; then
  RECORD_CHAIN=$(jq -cn --arg id "$CHAIN_ID" --argjson position "$POSITION" --argjson total "$TOTAL" '{chain_id:$id,position:$position,total:$total}') || exit 1
fi
ISSUE_URL=""; ISSUE_NUMBER=""; FILE_RC=0
if [ -z "$ISSUE_FILE" ]; then
  echo "ERROR: issue-file.sh not found (checked all three paths) — issue creation unavailable" >&2
  FILE_RC=5  # local dependency missing: nothing reached GitHub
else
  BODY_FILE=$(mktemp)
  cat > "$BODY_FILE" <<'ISSUE_BODY_7f34d1c9'
## Background
...
_Captured via /issue-maker._
ISSUE_BODY_7f34d1c9
  LABEL_ARGS=()
  while IFS= read -r l; do
    if [ -n "$l" ]; then LABEL_ARGS+=(--label "$l"); fi
  done <<< "$ACCEPTED_LABELS"
  ATTEMPT_STARTED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  FILED=$("$ISSUE_FILE" --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" \
    ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} --json) || FILE_RC=$?
  if [ "$FILE_RC" -eq 0 ]; then
    ISSUE_URL=$(printf '%s' "$FILED" | jq -r '.url')
    ISSUE_NUMBER=$(printf '%s' "$FILED" | jq -r '.number')
    # The labels actually applied, so Step 9 logs what the issue carries.
    ACCEPTED_LABELS=$(printf '%s' "$FILED" | jq -r '.labels[]')
  elif [ "$FILE_RC" -eq 4 ]; then
    # A dropped response can follow a successful GitHub create. Reconcile only
    # an exact title/body match created during this attempt; never retry blindly.
    if CANDIDATES=$(gh issue list --repo "$REPO" --state all --search "in:title $TITLE" \
      --limit 100 --json number,url,title,body,createdAt,labels); then
      MATCHES=$(printf '%s' "$CANDIDATES" | jq -c --arg repo "$REPO" --arg title "$TITLE" \
        --rawfile body "$BODY_FILE" --arg started "$ATTEMPT_STARTED_AT" '
        # GitHub timestamps are second-granularity here. Equal-second creates
        # are ambiguous across sessions, so fail closed and require reconciliation.
        [.[] | select(.title == $title and .body == $body and (.createdAt // "") > $started)
          | select((.url | split("/")[-4:-2]) == ($repo | split("/"))
            and (.url | split("/")[-1]) == (.number | tostring))]') || MATCHES="[]"
      MATCH_COUNT=$(printf '%s' "$MATCHES" | jq 'length' 2>/dev/null) || MATCH_COUNT=0
      if [ "$MATCH_COUNT" -eq 1 ]; then
        MATCH=$(printf '%s' "$MATCHES" | jq -c '.[0]')
        ISSUE_URL=$(printf '%s' "$MATCH" | jq -r '.url')
        ISSUE_NUMBER=$(printf '%s' "$MATCH" | jq -r '.number')
        ACCEPTED_LABELS=$(printf '%s' "$MATCH" | jq -r '.labels[]?.name')
        FILE_RC=0
        echo "WARN: issue-file.sh lost its create response; recovered exact matching issue #$ISSUE_NUMBER and will record its receipt" >&2
      else
        FILE_RC=6
        echo "ERROR: create response was uncertain and recent issues contained $MATCH_COUNT exact matches; do not retry or log until reconciled" >&2
      fi
    else
      FILE_RC=6
      echo "ERROR: create response was uncertain and the repository could not be checked; do not retry or log until reconciled" >&2
    fi
  fi
  rm -f "$BODY_FILE"
fi
echo "FILE_RC=$FILE_RC"
if [ "$FILE_RC" -eq 0 ]; then
  CREATE_RECEIPT=$(jq -cn --arg number "$ISSUE_NUMBER" --arg url "$ISSUE_URL" \
    --arg title "$TITLE" --arg labels "${ACCEPTED_LABELS:-}" --arg repo "$REPO" --arg tier "$ISSUE_TIER" --arg delivers "$DELIVERS" --argjson bound "$EST_BOUND" --argjson chain "$RECORD_CHAIN" \
    '{repo:$repo,tier:$tier,delivers:$delivers,bound:$bound,chain:$chain,number:($number|tonumber),url:$url,title:$title,labels:($labels|split("\n")|map(select(length>0)))}') || {
    echo "ERROR: remote create is confirmed, but its receipt could not be serialized; do not retry" >&2
    exit 1
  }
  printf 'CREATE_RECEIPT=%s\n' "$CREATE_RECEIPT"
fi
```

**`FILE_RC` non-zero blocks the next phase.** For exit 3, nothing reached GitHub: fix the title/body and rerun after its gates. Exit 5 means the local helper is unavailable and no GitHub write was attempted; repair installation before retrying. Exit 4 means the create response was uncertain; the reconciliation above either finds one exact issue created during this attempt and continues with its verified receipt, or returns `FILE_RC=6`. For 6, do not retry or write a log row until the remote result is reconciled. A label it dropped is not a failure — name it in the decision points (Step 9a).

**Phase-boundary receipt.** On `FILE_RC=0`, `CREATE_RECEIPT` is the confirmed remote number, URL, title, and applied-label array. Carry it into `create:postfile` and restore `ISSUE_NUMBER`, `ISSUE_URL`, `TITLE`, and `ACCEPTED_LABELS` from that JSON before writing the session row. After compaction, recover the same values from the tool output; never rerun the create block when a confirmed receipt exists. If the log write fails, keep the receipt in the recovery note and stop before reporting or offering a handoff.

---
