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

**New since the last scan (issue #1766).** An issue filed after this repo's previous backlog scan — an idea filed from the desk, or by `/issue-maker` — must show up in this scan's ranking without anyone pointing at it. This block fetches the backlog again (never a saved list) and picks the open, unassigned issues created after the baseline that carry none of the labels 1B.4 (6) excludes. The baseline is the repo's `pm_backlog_scan_at` (the previous scan's start, less five minutes of overlap), else the last 24 hours, and a complete fetch only prepares a candidate. Publish it after the same ranking has consumed the result.

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
PM_SCAN_PENDING=null
SCAN_NOW=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ) || SCAN_NOW=""
SCAN_SINCE=""; SCAN_KEY=""; SCAN_PRIOR_JSON=null; SCAN_PRIOR_VERIFIED=false
if [ -n "${SESSION_STATE_SH:-}" ]; then
  SCAN_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || SCAN_KEY=""
  if ! [[ "$SCAN_KEY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then SCAN_KEY=""; fi
  if [ -n "$SCAN_KEY" ]; then
    SCAN_PRIOR_RC=0
    SCAN_PRIOR_JSON=$("$SESSION_STATE_SH" --get-json ".repos[\"$SCAN_KEY\"].pm_backlog_scan_at" 2>/dev/null) || SCAN_PRIOR_RC=$?
    if [ "$SCAN_PRIOR_RC" -eq 3 ]; then SCAN_PRIOR_JSON=null; SCAN_PRIOR_RC=0; fi
    if [ "$SCAN_PRIOR_RC" -eq 0 ] &&
        SCAN_SINCE=$(jq -ers '
          select(length == 1) | .[0] |
          if . == null then ""
          else select(type == "string" and (try (fromdateiso8601 | todateiso8601) catch null) == .)
          end
        ' <<< "$SCAN_PRIOR_JSON" 2>/dev/null); then
      SCAN_PRIOR_VERIFIED=true
    fi
  fi
fi
if [ -n "$SCAN_SINCE" ]; then
  SINCE_FROM="the last scan"
else
  SCAN_SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ) || SCAN_SINCE=""
  SINCE_FROM="the last 24 h (no earlier scan recorded)"
fi
NEW_ISSUES='[]'
# The fetch names the repo whose baseline it reads, so the two always agree.
SCAN_OK=0
if [ -n "$SCAN_KEY" ]; then
  BACKLOG_NOW=$(gh issue list --repo "$SCAN_KEY" --state open --json number,title,labels,assignees,createdAt --limit 500 2>/dev/null) && SCAN_OK=1
else
  BACKLOG_NOW=$(gh issue list --state open --json number,title,labels,assignees,createdAt --limit 500 2>/dev/null) && SCAN_OK=1
fi
if [ "$SCAN_OK" -eq 1 ] && [ -n "$SCAN_SINCE" ] \
   && NEW_ISSUES=$(printf '%s' "$BACKLOG_NOW" | jq -ce --arg since "$SCAN_SINCE" '
        def utc: type == "string" and (try (fromdateiso8601 | todateiso8601) catch null) == .;
        select(($since | utc) and type == "array" and
          all(.[]; type == "object" and
            (.number | type == "number" and . > 0 and floor == .) and
            (.title | type == "string") and (.createdAt | utc))) |
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
  elif [ -z "$SCAN_KEY" ]; then
    echo "DEGRADED: no repo key from session-state.sh — new issues are judged against the last 24 h, and no baseline is kept"
  elif [ "$SCAN_PRIOR_VERIFIED" = true ] && [ -n "$SCAN_NOW" ]; then
    PM_SCAN_PENDING=$(jq -cn --arg repo "$SCAN_KEY" --argjson prior "$SCAN_PRIOR_JSON" \
      --arg next "$SCAN_NOW" '{repo:$repo,prior:$prior,next:$next}') || PM_SCAN_PENDING=null
  else
    echo "DEGRADED: the prior backlog-scan watermark or clock could not be verified — the baseline did not move"
  fi
  printf 'NEW_ISSUES since %s (%s): %s\n' "$SCAN_SINCE" "$SINCE_FROM" \
    "$(printf '%s' "$NEW_ISSUES" | jq -r 'if length == 0 then "none" else map("#\(.number) \(.title)") | join("; ") end')"
else
  NEW_ISSUES='[]'
  echo "DEGRADED: the new-issue scan failed (gh issue list or jq) — no issue is marked new this run, and the baseline did not move"
fi
printf 'PM_SCAN_PENDING=%s\n' "$PM_SCAN_PENDING"
```

Carry only this attempt's `PM_SCAN_PENDING` into its completion. A later
fetch starts with a fresh receipt. Use the publication block only when
the ranking based on this fetch is complete and its result has been
emitted or durably saved. Every candidate in `NEW_ISSUES` must have a final
rank or definitive exclusion. For a completed bounded rescan in 3.4, run
the same block after its final ranking is saved. An interruption or failed
ranking leaves the watermark unchanged.

<!-- test-anchor: pm-new-issue-scan-publish -->
```bash
pm_publish_scan_watermark() {
  local scope binding prior next watermark_path
  [ "${PM_SCAN_RANK_COMPLETE:-false}" = true ] || return 4
  scope=$("$SESSION_STATE_SH" --repo-key) || return 4
  [[ "$scope" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 4
  binding=$(jq -cse --arg repo "$scope" '
    def utc: type == "string" and (try (fromdateiso8601 | todateiso8601) catch null) == .;
    select(length == 1) | .[0] | objects |
    select(.repo == $repo and (.next | utc)) |
    select(.prior == null or ((.prior | utc) and .next > .prior))
  ' <<< "${PM_SCAN_PENDING:-null}") || return 4
  prior=$(jq -c '.prior' <<< "$binding") || return 4
  next=$(jq -c '.next' <<< "$binding") || return 4
  watermark_path=".repos[\"$scope\"].pm_backlog_scan_at"
  "$SESSION_STATE_SH" --cas "$watermark_path=$next" --expect "$prior"
}

if [ "${PM_SCAN_RANK_COMPLETE:-false}" = true ] && [ "${PM_SCAN_PENDING:-null}" != null ]; then
  SCAN_PUBLISH_RC=0
  pm_publish_scan_watermark || SCAN_PUBLISH_RC=$?
  if [ "$SCAN_PUBLISH_RC" -ne 0 ] && [ "$SCAN_PUBLISH_RC" -ne 7 ]; then
    echo "DEGRADED: the backlog-scan baseline was not saved — the next scan reads the same window again"
  fi
fi
```

Set `PM_SCAN_RANK_COMPLETE=true` only after that completion check.
A comparison loss leaves the competing watermark alone. Do not retry
with a new expected watermark from this old ranking.
