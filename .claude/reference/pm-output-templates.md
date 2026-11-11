# PM Output Templates

Presentation format templates for `/pm` Step 1B.5. Extracted from `pm/SKILL.md` to reduce churn surface on the formatting-only blocks. Referenced by Step 1B.5 for output format guidance.

---

## User-Scoped Sections (Step 1B.5)

`## Forgotten PRs` **always** renders — `forgotten-pr-triage.sh` defaults to `@me`, so it runs regardless of whether `$GH_USER` is set. The three `$GH_USER`-dependent sections render only when `$GH_USER` is set.

When `$GH_USER` is set, render all four in this order before the backlog ranking; when `$GH_USER` is **not** set, render only `## Forgotten PRs` in the same position (before `## Suggested Next Issues`):

```
## Your Open PRs
{List of open PRs authored by $GH_USER with last update time — or "none" if empty — only when $GH_USER is set}

## Forgotten PRs (>N days)
{Step 1D output — the forgotten set with per-PR close/merge recommendations, or a one-line "none" note when empty. Informational; never alters the ranking below. Always rendered.}

## PRs Awaiting Your Review
{List of open PRs where $GH_USER is a requested reviewer — or "none" if empty — only when $GH_USER is set}

## Issues Assigned to You
{List of open issues assigned to $GH_USER — or "none" if empty — only when $GH_USER is set}
```

---

## Suggested Next Issues (Step 1B.5)

Display the top 3–5 backlog issues for pickup. The initial inline batch uses
Step 0's `LIMIT` from the full operator-first ranking, subject to the launch
gates. Each displayed issue shows its per-issue estimate resolved via
`estimate-resolve.sh` (body `## Estimate` section → tier-label fallback → `unestimated`).

Rows from the operator's `/desk` order (`/pm` 1B.4 item 7, issue #1767) come first, each marked
`Operator order (desk) #k` beside its other annotations — k is its place among the override rows —
then fill the remaining display rows from the ranking. The context line names the operator-priority status:
`N ordered, M parked`, `none`, or `unreadable`. The `Parked (desk):` and `Not eligible (desk):`
lines appear only when they have entries.

```
## Suggested Next Issues

Based on {N} open issues, {M} recent merges, {OKR status}, and operator priority {4 ordered, 2 parked}:

1. **#42 — {Title}** — {1-line rationale connecting to business value or OKR}
   - Labels: {labels} | Age: {days} days | Operator order (desk) #1 | Unblocks: #50, #53
   - Est: 45–90 min · plan on 90

2. **#38 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days | Operator order (desk) #2 | Blocked by: #35
   - Est: 15–30 min · plan on 30

3. **#55 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: unestimated

4. **#61 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: 90–180 min · plan on 180

5. **#47 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days
   - Est: 45–90 min · plan on 90

Parked (desk): #57 until 2026-10-09, #64 until 2026-10-12
Not eligible (desk): #49 — open PR #120; #51 — closed

### Already In-Flight
{List open PRs with their linked issues — these don't need new threads}

### Dependency Note
{If any suggested issues have dependency chains, note the order}
```

**Resolve order for Est:** call `estimate-resolve.sh <N>` (resolved per the portable-skill-resolution.md
candidate order). If the script is unavailable, omit the `- Est:` line silently — the estimate is
informational and never a dispatch blocker.

---

## Full Ranking / Tiered View (Step 1B.5)

When the user asks to "rank the backlog", "priority list", or "full ranking", replace the top 3-5 list with the tiered view. "Full" means every tier is covered, not that every issue is listed: name the issues that earn a decision in each tier and summarize the rest. Omit any tier with no issues:

```
## Operator order (desk)
- **#61 — {title}** — {rationale} · Operator order (desk) #1 · ranked Medium
- **#38 — {title}** — {rationale} · Operator order (desk) #2 · ranked High
Parked (desk): #57 until 2026-10-09
Not eligible (desk): #49 — open PR #120

## Critical — must do to achieve the goal
- **#42 — {title}** — {1-line rationale tying the issue to the goal or OKR}
  - Unblocks: #50, #53 | Advances: O1/KR2

## High — significant enablers
- **#55 — {title}** — {rationale}

## Medium — supporting work (defer if necessary)
- **#66 — {title}** — {rationale}

## Low — tangential (skip for now)
- **#70 — {title}** — {rationale}

## Stop doing
{Only when 1B.4 flagged misaligned effort: name the current low-impact work and the
higher-impact work to switch to. Omit entirely when current work is well-aligned.}
```

Summarize rather than enumerate once a tier stops informing a decision — most often the Low tier: "68 additional issues are Low-priority relative to this goal". The tier still appears with its heading; it just carries a count instead of 68 bullets.

The `## Operator order (desk)` section appears only when the operator ordered or parked something (`/pm` 1B.1a). Its rows are listed once, there, with the tier they would have ranked in (`ranked Medium`), and are left out of the tier sections below — so dropping one from the override puts it straight back in its tier.

## PM progress report

The owner requests a changed-board report every 30 minutes by default for
`/pm` threads. A repo's `report_every_min` in `## Reporting` changes the
interval when positive. Zero opts out. The existing `/pm day` tick, PM-owned inline monitor
tick and PM terminal completion turn are its only automatic entry points.
Consolidate the turn's outcomes and evaluate once. Explicit status renders
`/board` immediately. It does not consume an automatic report's outcomes.

Use current, already collected board and phase evidence. Supply
`PM_REPORT_BOARD_JSON` with four arrays:

- `running` contains `{issue,phase,pr}` rows from this round. Phases are `A`,
  `B` and `C`. Use null for a pipeline without a PR.
- `queued` contains issue numbers in queue order.
- `needs` contains `{issue,reason}` rows only for genuine owner actions.
- `terminal` contains `{key,issue,pr,outcome}` rows for verified outcomes, with
  `outcome` either `merged` or `blocked`. Build the key from the durable
  pipeline start, issue number and outcome. Use the round's dispatch identity
  when a terminal outcome occurred before a launch timestamp was recorded.
  Preserve outcome evidence until it can be reported. Read all three phases'
  terminal results. A Phase C success requires GitHub's merge confirmation.

Exclude timestamps that only represent polling time, countdowns, and raw
diagnostics from the input. A successful run with no terminal events still
passes an explicit empty array. Skip the automatic report when the board
evidence or current repo/session identity is unavailable.

Run the gate in the PM thread with its resolved helpers. Keep `REPORT_RESULT`, `REPORT_BEFORE` and `REPORT_PATH` from this check for the receipt step. Rebind those exact values if delivery and receipt use separate shell calls.
A malformed setting or unreadable report receipt yields a diagnostic and no
automatic render. The absence of an initial receipt starts the cadence
without emitting a startup report.

<!-- test-anchor: pm-progress-report-check -->
```bash
REPORT_RESULT=''
REPORT_BEFORE=''
REPORT_PATH=''
REPORT_CONFIG=''
REPORT_CONFIG_RC=0
# A missing config supplies the default even when the optional reader is absent.
# An existing path needs a real read so its opt-out cannot be skipped.
if [[ -e .claude/pm-config.md || -L .claude/pm-config.md ]]; then
  if [[ -n "${PM_CONFIG_GET:-}" ]]; then
    REPORT_CONFIG=$("$PM_CONFIG_GET" --section Reporting) || REPORT_CONFIG_RC=$?
  else
    REPORT_CONFIG_RC=4
  fi
fi
if [[ "$REPORT_CONFIG_RC" -gt 1 ]]; then
  printf '%s\n' 'DEGRADED: PM Reporting configuration unavailable; scheduled reports paused' >&2
elif [[ -z "${PM_REPORT_SH:-}" ]]; then
  if ! grep -Eq '^[[:blank:]]*report_every_min[[:blank:]]*:[[:blank:]]*0+[[:blank:]]*$' <<< "$REPORT_CONFIG"; then
    printf '%s\n' 'DEGRADED: PM report helper missing. Scheduled reports are paused and explicit /board remains available.' >&2
  fi
elif [[ -n "${SESSION_STATE_SH:-}" ]] \
  && REPORT_MIN=$(printf '%s' "$REPORT_CONFIG" | "$PM_REPORT_SH" --config-only) \
  && [[ "$REPORT_MIN" != 0 ]]; then
  REPORT_REPO=$("$SESSION_STATE_SH" --repo-key) || REPORT_REPO=''
  REPORT_SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [[ "$REPORT_REPO" == */* && -n "$REPORT_SESSION" && "$REPORT_SESSION" != default ]]; then
    REPORT_PATH=$(jq -nr --arg repo "$REPORT_REPO" --arg session "$REPORT_SESSION" \
      '".repos[\($repo|tojson)].pm_reports[\($session|tojson)]"') || REPORT_PATH=''
    if [[ -n "$REPORT_PATH" ]]; then
      REPORT_RC=0
      REPORT_BEFORE=$("$SESSION_STATE_SH" --get "$REPORT_PATH" 2>/dev/null) || REPORT_RC=$?
      if [[ "$REPORT_RC" -eq 3 ]]; then
        REPORT_BEFORE=null
        REPORT_RC=0
      fi
      if [[ "$REPORT_RC" -eq 0 ]]; then
        REPORT_RESULT=$(jq -cn --arg config "$REPORT_CONFIG" \
          --argjson board "${PM_REPORT_BOARD_JSON:-null}" --argjson previous "$REPORT_BEFORE" \
          '{config:$config,board:$board,previous:$previous}' | "$PM_REPORT_SH") || REPORT_RESULT=''
      else
        printf 'pm-report: unreadable report receipt (exit %s)\n' "$REPORT_RC" >&2
      fi
    fi
  fi
fi
```

A result with `due:true` is the only automatic render signal. Run `/board`
once and append the nonempty groups in this order. Use its canonical
`Running now` table. If the final outcome left an empty board, keep its
canonical no-active-round line. Use the output's `groups` object for the list.
Keep `blocked` visible as the outcome on its Done entry and use Needs you
only when the blocker requires owner action.

```markdown
- **Done since last report**
  - #42 — merged, PR #88
- **Working**
  - #38 → Phase B → PR #91
- **Up next**
  - #55
- **Needs you**
  - #67 — choose a delivery scope
```

Refresh and link the [project board](#persistent-project-board) before delivery.
After the whole report reaches the user, set `REPORT_DELIVERED=1`. Initialize
it to zero before attempting delivery. Use the receipt snippet in the same
turn. A reported event is remembered by its exact key, so repeating a
completion callback cannot reset the clock or announce it again. A blocked
outcome or final merge is immediately eligible even with an empty board.
Preserve an unsuccessful receipt write as a diagnostic and reconcile the
current record before attempting delivery again.

<!-- test-anchor: pm-progress-report-receipt -->
```bash
REPORT_NEXT=''
if [[ -n "${REPORT_RESULT:-}" && -n "${REPORT_PATH:-}" ]]; then
  REPORT_NEXT=$(jq -c --arg delivered "${REPORT_DELIVERED:-0}" '
    if .due == true and $delivered == "1" then .after_delivery
    elif .due == false then .initialize // empty
    else empty end
  ' <<< "$REPORT_RESULT") || REPORT_NEXT=''
fi
if [[ -n "$REPORT_NEXT" ]]; then
  "$SESSION_STATE_SH" --cas "$REPORT_PATH=$REPORT_NEXT" --expect "$REPORT_BEFORE"
fi
```

## Persistent project board

A verified dispatch or refill, a verified `merged` or `blocked` outcome,
or a due scheduled report refreshes the project page. Consolidate all
three signals for the turn. Publishing the file has no chat-render
effect and does not advance the `/board` freshness clock. Use the
existing PM turn and its already gathered evidence.

Set `PM_BOARD_DISPATCHED` and `PM_BOARD_TERMINAL` to `true` only for
verified events this turn. Reuse the scheduled gate's `REPORT_RESULT`.
Resolve the current file before gathering the display projection. This
reads the last complete publication and provides a compare-and-set digest.

<!-- test-anchor: pm-project-board-begin -->
```bash
PM_BOARD_REPO=''
PM_BOARD_PATH=''
PM_BOARD_EXPECT=''
PM_BOARD_PAGE_SH=''
if [[ "${PM_BOARD_DISPATCHED:-false}" == true || "${PM_BOARD_TERMINAL:-false}" == true ]] ||
    jq -e '.due == true' <<<"${REPORT_RESULT:-null}" >/dev/null 2>&1; then
  PM_BOARD_PAGE_SH=$(resolve_script pm-board-page.sh || true)
  if [[ -z "$PM_BOARD_PAGE_SH" || -z "${SESSION_STATE_SH:-}" ]]; then
    printf '%s\n' 'DEGRADED: project board helper unavailable' >&2
  else
    PM_BOARD_REPO=$("$SESSION_STATE_SH" --repo-key) || PM_BOARD_REPO=''
    if [[ "$PM_BOARD_REPO" == */* ]]; then
      PM_BOARD_CURRENT=$("$PM_BOARD_PAGE_SH" --repo "$PM_BOARD_REPO" --current) || PM_BOARD_CURRENT=''
      PM_BOARD_EXPECT=$(jq -er --arg repo "$PM_BOARD_REPO" '
        select(.repo == $repo)
        | if .digest == null and .path == null then "absent"
          elif (.digest | type == "string" and test("^[0-9a-f]{64}$")) and
               (.path | type == "string" and startswith("/"))
          then .digest else empty end
      ' <<<"$PM_BOARD_CURRENT") || PM_BOARD_EXPECT=''
      PM_BOARD_PATH=$(jq -r --arg repo "$PM_BOARD_REPO" '
        select(.repo == $repo) | .path | select(type == "string" and startswith("/"))
      ' <<<"$PM_BOARD_CURRENT") || PM_BOARD_PATH=''
    fi
  fi
fi
```

With a valid `PM_BOARD_EXPECT`, assemble `PM_BOARD_PAGE_JSON` as an
object with the exact `repo` and a `rows` array. Reuse `/board`'s
positive running evidence, recorded round and queue order, current
GitHub issue/PR state and estimate/projected-end lookup. Use the same
repository's verified work across its dispatchers, including current
terminal deliveries. A recorded queue or a stale pre-PR row alone cannot
prove a live pipeline. Reuse verified titles and estimates from this
turn's evidence. Obtain missing data only for the displayed rows.

- Each row carries `repo`, positive integer `issue`, and `group` of
  `needs`, `running`, `queued` or `done`. Include the title, integer `pr`
  when available, phase `A`, `B` or `C`, `estimate` as integer
  `{low,high,plan}` minutes, and the canonical `ends_at` in UTC where known.
- A verified merge has `group:done`, `outcome:merged` and its merged PR
  number. A verified blocked result has `outcome:blocked`. Use `needs`
  when an owner action is required and point to `/desk` for decisions.
  Use `done` for a verified block that needs no owner action. Follow
  `/board`'s exclusion of closed-unmerged work unless PM verified a
  blocked outcome for it. A verified merge or block replaces its older
  running or queued row. Deduplicate after scoping to the current repo.
- For split work, use the tracked child set and verified parent links.
  Include the visible chain's confirmed merged children and other
  recorded children with their own states. Supply each child's integer
  `parent`. A terminal block does not count as a merged child.
- The renderer lists scoped local handoff filenames. Optional `notes`
  entries are `{repo,name}` from an already scoped notes source. An optional
  `receipt` contains the exact `repo` and `statuses` array. Project only
  the latest verified run receipt's expected step statuses for this repo.
  Use `unrecorded` for expected steps with no mark. Omit receipt reasons.
- Exclude raw bodies, environment values, diagnostics, handoff contents
  and full notes paths. If the scoped evidence is unreadable, preserve
  the previous page. An affirmatively empty board uses `rows:[]`.

The normal location is the private local file
`~/.claude/boards/<owner>/<repo>/board.html`. A runtime with a private
Artifact publisher can instead use it after the operator chooses publication.
Run the renderer with `--repo "$PM_BOARD_REPO" --html` and the same
scoped JSON for the publisher. Read the existing location before creating
an artifact. Publish once per repo and update that artifact at its stable
private URL. Use the local route when private publication is unavailable
or the choice is unset.

<!-- test-anchor: pm-project-board-publish -->
```bash
PM_BOARD_RESULT=''
if [[ -n "${PM_BOARD_EXPECT:-}" ]]; then
  if [[ -n "${PM_BOARD_PAGE_JSON:-}" ]]; then
    PM_BOARD_RESULT=$(printf '%s' "$PM_BOARD_PAGE_JSON" |
      "$PM_BOARD_PAGE_SH" --repo "$PM_BOARD_REPO" --expect-digest "$PM_BOARD_EXPECT") ||
      PM_BOARD_RESULT=''
  else
    printf '%s\n' 'DEGRADED: project board evidence unavailable' >&2
  fi
fi
if [[ -n "$PM_BOARD_RESULT" ]]; then
  PM_BOARD_PUBLISHED_PATH=$(jq -er --arg repo "$PM_BOARD_REPO" '
    select(.repo == $repo) | .path | select(type == "string" and startswith("/"))
  ' <<<"$PM_BOARD_RESULT") || PM_BOARD_PUBLISHED_PATH=''
  if [[ -n "$PM_BOARD_PUBLISHED_PATH" ]]; then
    PM_BOARD_PATH="$PM_BOARD_PUBLISHED_PATH"
    PM_BOARD_STATE_PATH=$(jq -nr --arg repo "$PM_BOARD_REPO" '".repos[\($repo|tojson)].pm_board_page"') ||
      PM_BOARD_STATE_PATH=''
    PM_BOARD_NEXT=$(jq -cn --arg location "$PM_BOARD_PATH" '{location:$location}') || PM_BOARD_NEXT=''
    PM_BOARD_STATE_RC=4
    if [[ -n "$PM_BOARD_STATE_PATH" && -n "$PM_BOARD_NEXT" ]]; then
      PM_BOARD_STATE_RC=0
      PM_BOARD_BEFORE=$("$SESSION_STATE_SH" --repo "$PM_BOARD_REPO" --get-json "$PM_BOARD_STATE_PATH") ||
        PM_BOARD_STATE_RC=$?
    fi
    if [[ "$PM_BOARD_STATE_RC" -eq 3 ]]; then
      PM_BOARD_BEFORE=null
      PM_BOARD_STATE_RC=0
    fi
    if [[ "$PM_BOARD_STATE_RC" -ne 0 ]]; then
      printf '%s\n' 'DEGRADED: project board location state unavailable' >&2
    elif [[ "$PM_BOARD_BEFORE" != "$PM_BOARD_NEXT" ]]; then
      "$SESSION_STATE_SH" --repo "$PM_BOARD_REPO" \
        --cas "$PM_BOARD_STATE_PATH=$PM_BOARD_NEXT" --expect "$PM_BOARD_BEFORE" >/dev/null ||
        printf '%s\n' 'DEGRADED: project board location could not be recorded' >&2
    fi
  fi
fi
```

Record an explicitly selected private Artifact URL in the same `location`
field after a verified update. Store neither the rows nor the HTML in
session state. Add a **Project board** link to each scheduled report, using
the path from this publication or the previously verified file if the
refresh failed. Note a failed refresh when linking that prior file. If
there is no verified location, surface that failure and deliver the
progress report. The rendered page refreshes itself while visible.
