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
ISSUE_URL=""; ISSUE_NUMBER=""; FILE_RC=0
if [ -z "$ISSUE_FILE" ]; then
  echo "ERROR: issue-file.sh not found (checked all three paths) — issue creation unavailable" >&2
  FILE_RC=5  # local dependency missing: nothing reached GitHub
else
  BODY_FILE=$(mktemp)
  cat > "$BODY_FILE" <<'EOF'
## Background
...
_Captured via /issue-maker._
EOF
  LABEL_ARGS=()
  while IFS= read -r l; do
    if [ -n "$l" ]; then LABEL_ARGS+=(--label "$l"); fi
  done <<< "$ACCEPTED_LABELS"
  FILED=$("$ISSUE_FILE" --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" \
    ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} --json) || FILE_RC=$?
  rm -f "$BODY_FILE"
  if [ "$FILE_RC" -eq 0 ]; then
    ISSUE_URL=$(printf '%s' "$FILED" | jq -r '.url')
    ISSUE_NUMBER=$(printf '%s' "$FILED" | jq -r '.number')
    # The labels actually applied, so Step 9 logs what the issue carries.
    ACCEPTED_LABELS=$(printf '%s' "$FILED" | jq -r '.labels[]')
  fi
fi
echo "FILE_RC=$FILE_RC"
```

**`FILE_RC` non-zero → this issue was not filed.** Report `issue-file.sh`'s stderr lines and the exit code, write **no** log row (Step 9), and print no URL for it. Exit 5 means the local helper is unavailable and no GitHub write was attempted; repair installation before retrying. Exit 3 means nothing reached GitHub: fix the title or body it named and run the block again. Exit 4 means `gh` failed, and the issue may have landed anyway (a lost response after the write): check the repo's newest issues before filing again, so a retry never files a duplicate. A label it dropped is not a failure — name it in the decision points (Step 9a).

---
