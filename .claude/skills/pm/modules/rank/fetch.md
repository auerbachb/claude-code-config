<!-- pm-routing:begin -->
Route `rank:fetch`. Fetch scoped GitHub state after the rank load. A bounded backlog rescan may enter here with current scope and operator evidence.
<!-- pm-routing:end -->
### 1B.2: Fetch GitHub state

```bash
# Recent merged PRs — understand momentum and direction
gh pr list --state merged --limit 20 --json number,title,mergedAt,author,body

# Open issues — the backlog
gh issue list --state open --json number,title,labels,assignees,createdAt,updatedAt --limit 500

# Open PRs (ALL authors) — used ONLY to detect in-flight work for dedup: skip an
# issue that already has a PR, no matter whose. The author field distinguishes
# yours from collaborators'. Ceiling/slot COUNTS and merge/actionable OFFERS are
# built only from PRs you authored (author == $GH_USER / @me) — never this full
# set. A collaborator's backlog is at most FYI context, never a gate (issue #732).
gh pr list --state open --json number,title,headRefName,author,updatedAt,additions,deletions,body

# User-scoped views (only if $GH_USER is set from Step 0a)
if [ -n "$GH_USER" ]; then
  # Your own open PRs — highest priority when asking "what's next"
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt,headRefName

  # PRs awaiting your review — others are blocked on you
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt

  # Issues assigned to you — committed work
  gh issue list --state open --assignee "$GH_USER" --json number,title,labels,updatedAt
fi
```

**Truncation check:** If the returned issue count equals 500, warn: "Showing 500 issues — repo may have more. Results may be incomplete."

**New since the last scan (issue #1766).** An issue filed after this repo's previous backlog scan — an idea filed from the desk, or by `/issue-maker` — must show up in this scan's ranking without anyone pointing at it. This block fetches the backlog again (never a saved list) and picks the open, unassigned issues created after the baseline that carry none of the labels 1B.4 (6) excludes. The baseline is the repo's `pm_backlog_scan_at` (the previous scan's start, less five minutes of overlap), else the last 24 hours, and it moves only after a successful, complete fetch:

<!-- test-anchor: pm-1b2-new-issues -->
```bash
if [ -z "${SESSION_STATE_SH:-}" ]; then
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh}" \
    "${HOME:+$HOME/.claude/scripts/session-state.sh}" \
    ".claude/scripts/session-state.sh"; do
    if [ -x "$candidate" ]; then SESSION_STATE_SH="$candidate"; break; fi
  done
fi
# The next baseline: taken before the fetch and set back 5 minutes, so a local
# clock running ahead of GitHub's never skips an issue (one filed inside the
# overlap is named on two scans, which is harmless).
SCAN_NOW=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)
SCAN_SINCE=""; SCAN_KEY=""
if [ -n "${SESSION_STATE_SH:-}" ]; then
  SCAN_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || SCAN_KEY=""
  if [ "$SCAN_KEY" = "_unknown" ]; then SCAN_KEY=""; fi
  if [ -n "$SCAN_KEY" ]; then
    SCAN_SINCE=$("$SESSION_STATE_SH" --get ".repos[\"$SCAN_KEY\"].pm_backlog_scan_at" 2>/dev/null) || SCAN_SINCE=""
  fi
fi
case "$SCAN_SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) SINCE_FROM="the last scan" ;;
  *) SCAN_SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)
     SINCE_FROM="the last 24 h (no earlier scan recorded)" ;;
esac
NEW_ISSUES='[]'
# The fetch names the repo whose baseline it reads, so the two always agree.
SCAN_OK=0
if [ -n "$SCAN_KEY" ]; then
  BACKLOG_NOW=$(gh issue list --repo "$SCAN_KEY" --state open --json number,title,labels,assignees,createdAt --limit 500 2>/dev/null) && SCAN_OK=1
else
  BACKLOG_NOW=$(gh issue list --state open --json number,title,labels,assignees,createdAt --limit 500 2>/dev/null) && SCAN_OK=1
fi
if [ "$SCAN_OK" -eq 1 ] \
   && NEW_ISSUES=$(printf '%s' "$BACKLOG_NOW" | jq -c --arg since "$SCAN_SINCE" '
        [ .[] | select(.createdAt >= $since)
              | select(((.assignees // []) | length) == 0)
              | select([(.labels // [])[].name | ascii_downcase]
                       | any(IN("blocked", "on-hold", "wontfix", "duplicate")) | not)
              | {number, title, createdAt} ] | sort_by(.createdAt)'); then
  # `gh issue list` returns newest first, so a 500-row cap drops only old
  # issues — unless all 500 are newer than the baseline. Then some new ones
  # may be missing: keep the baseline so the next scan reads the window again.
  SCAN_FULL=$(printf '%s' "$BACKLOG_NOW" | jq -r --arg since "$SCAN_SINCE" \
    'if length >= 500 and ((map(.createdAt) | min) >= $since) then "yes" else "no" end' 2>/dev/null) || SCAN_FULL=yes
  if [ "$SCAN_FULL" != "no" ]; then
    echo "DEGRADED: the list hit its 500-issue cap with every row newer than $SCAN_SINCE, so some new issues may be missing — the baseline did not move"
  elif [ -n "$SCAN_KEY" ]; then
    "$SESSION_STATE_SH" --set ".repos[\"$SCAN_KEY\"].pm_backlog_scan_at=\"$SCAN_NOW\"" >/dev/null 2>&1 \
      || echo "DEGRADED: the backlog-scan baseline was not saved — the next scan reads the same window again"
  else
    echo "DEGRADED: no repo key from session-state.sh — new issues are judged against the last 24 h, and no baseline is kept"
  fi
  printf 'NEW_ISSUES since %s (%s): %s\n' "$SCAN_SINCE" "$SINCE_FROM" \
    "$(printf '%s' "$NEW_ISSUES" | jq -r 'if length == 0 then "none" else map("#\(.number) \(.title)") | join("; ") end')"
else
  NEW_ISSUES='[]'
  echo "DEGRADED: the new-issue scan failed (gh issue list or jq) — no issue is marked new this run, and the baseline did not move"
fi
```

