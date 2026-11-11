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

Top 3-5 backlog issues for pickup. Each issue shows its per-issue estimate resolved via
`estimate-resolve.sh` (body `## Estimate` section → tier-label fallback → `unestimated`).

Rows from the operator's `/desk` order (`/pm` 1B.4 item 7, issue #1767) come first, each marked
`Operator order (desk) #k` beside its other annotations — k is its place among the override rows —
then ranked rows up to five in all. The context line names the operator-priority status:
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

## Opt-in PM progress report

A positive `report_every_min` in the repo's `## Reporting` section is a standing
status request for `/pm`. The existing `/pm day` tick, PM-owned inline monitor
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
if [[ -n "${PM_CONFIG_GET:-}" && -n "${PM_REPORT_SH:-}" && -n "${SESSION_STATE_SH:-}" ]] \
  && REPORT_CONFIG=$("$PM_CONFIG_GET" --section Reporting) \
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
