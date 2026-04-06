---
name: standup
description: Generate a daily standup summary of what was accomplished since the last standup, from a business logic perspective. Reads PR bodies to understand what changes actually enabled.
argument-hint: "[since-time] — omit for smart default (skips weekends/holidays); e.g. \"Friday at noon ET\""
---

Generate a standup report summarizing what was accomplished since $ARGUMENTS (default: smart lookback to previous workday noon ET — skips weekends and US federal holidays).

## How to gather data

### Step 1: Find repos and set time range

1. **Find all repos the user works in.** Check recent git activity across known repo paths. Start with the current working directory, then check other repos mentioned in conversation context or memory.

2. **Determine the lookback cutoff.** If the user provided an explicit `$ARGUMENTS` time reference, use it directly (skip to the ISO conversion below). If no argument was given, compute the smart default: find the most recent prior workday by walking backwards from yesterday, skipping weekends and US federal holidays.

   **Smart lookback algorithm** (run only when `$ARGUMENTS` is empty):

   ```bash
   # --- Cross-platform date helpers ---
   get_day_of_week() {
     # Returns 0=Sun 1=Mon ... 6=Sat for a YYYY-MM-DD date
     TZ='America/New_York' date -d "$1" '+%w' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d' "$1" '+%w'
   }

   subtract_days() {
     # subtract_days YYYY-MM-DD N → returns YYYY-MM-DD minus N days
     TZ='America/New_York' date -d "$1 - $2 days" '+%Y-%m-%d' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d' -v-"$2"d "$1" '+%Y-%m-%d'
   }

   get_nth_weekday_of_month() {
     # get_nth_weekday_of_month N WEEKDAY YYYY-MM
     # N=occurrence (1-5), WEEKDAY=0-6 (Sun-Sat), YYYY-MM=year-month
     # Returns YYYY-MM-DD of the Nth occurrence of WEEKDAY in that month
     local n=$1 wd=$2 ym=$3
     local count=0 d=1
     while true; do
       local candidate="${ym}-$(printf '%02d' $d)"
       local dow
       dow=$(get_day_of_week "$candidate")
       if [ "$dow" -eq "$wd" ]; then
         count=$((count + 1))
         if [ "$count" -eq "$n" ]; then
           echo "$candidate"
           return
         fi
       fi
       d=$((d + 1))
       [ "$d" -gt 31 ] && return 1
     done
   }

   get_last_weekday_of_month() {
     # get_last_weekday_of_month WEEKDAY YYYY-MM
     # Returns the last occurrence of WEEKDAY (0-6) in the given month
     local wd=$1 ym=$2
     local last=""
     local d=1
     while true; do
       local candidate="${ym}-$(printf '%02d' $d)"
       # Check if we've rolled into the next month
       local check_month
       check_month=$(printf '%s' "$candidate" | cut -d- -f1-2)
       [ "$check_month" != "$ym" ] && break
       local dow
       dow=$(get_day_of_week "$candidate" 2>/dev/null) || break
       if [ "$dow" -eq "$wd" ]; then
         last="$candidate"
       fi
       d=$((d + 1))
       [ "$d" -gt 31 ] && break
     done
     echo "$last"
   }

   apply_observed_rule() {
     # If a fixed holiday falls on Sat, observe on Fri. If Sun, observe on Mon.
     local date=$1
     local dow
     dow=$(get_day_of_week "$date")
     if [ "$dow" -eq 6 ]; then
       subtract_days "$date" 1   # Saturday → Friday
     elif [ "$dow" -eq 0 ]; then
       # Add 1 day: Sun → Mon
       TZ='America/New_York' date -d "$date + 1 day" '+%Y-%m-%d' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d' -v+1d "$date" '+%Y-%m-%d'
     else
       echo "$date"
     fi
   }

   # --- Holiday computation ---
   compute_holidays_for_year() {
     local y=$1
     local holidays=""

     # Fixed-date holidays (with observed-date rules)
     holidays="$holidays $(apply_observed_rule "$y-01-01")"  # New Year's Day
     holidays="$holidays $(apply_observed_rule "$y-06-19")"  # Juneteenth
     holidays="$holidays $(apply_observed_rule "$y-07-04")"  # Independence Day
     holidays="$holidays $(apply_observed_rule "$y-11-11")"  # Veterans Day
     holidays="$holidays $(apply_observed_rule "$y-12-25")"  # Christmas Day

     # Floating holidays
     holidays="$holidays $(get_nth_weekday_of_month 3 1 "$y-01")"  # MLK Day: 3rd Mon Jan
     holidays="$holidays $(get_nth_weekday_of_month 3 1 "$y-02")"  # Presidents' Day: 3rd Mon Feb
     holidays="$holidays $(get_last_weekday_of_month 1 "$y-05")"   # Memorial Day: last Mon May
     holidays="$holidays $(get_nth_weekday_of_month 1 1 "$y-09")"  # Labor Day: 1st Mon Sep
     holidays="$holidays $(get_nth_weekday_of_month 2 1 "$y-10")"  # Columbus Day: 2nd Mon Oct

     local thanksgiving
     thanksgiving=$(get_nth_weekday_of_month 4 4 "$y-11")          # Thanksgiving: 4th Thu Nov
     holidays="$holidays $thanksgiving"

     # Day after Thanksgiving (Friday)
     local day_after
     day_after=$(TZ='America/New_York' date -d "$thanksgiving + 1 day" '+%Y-%m-%d' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d' -v+1d "$thanksgiving" '+%Y-%m-%d')
     holidays="$holidays $day_after"

     echo "$holidays"
   }

   # Compute holidays for current and previous year (handles year boundaries)
   CURRENT_YEAR=$(TZ='America/New_York' date '+%Y')
   PREV_YEAR=$((CURRENT_YEAR - 1))
   HOLIDAYS="$(compute_holidays_for_year "$CURRENT_YEAR") $(compute_holidays_for_year "$PREV_YEAR")"

   is_workday() {
     local date=$1
     local dow
     dow=$(get_day_of_week "$date")
     # Weekend check: 0=Sun, 6=Sat
     [ "$dow" -eq 0 ] && return 1
     [ "$dow" -eq 6 ] && return 1
     # Holiday check
     case " $HOLIDAYS " in
       *" $date "*) return 1 ;;
     esac
     return 0
   }

   # --- Walk backward from yesterday to find last workday ---
   CANDIDATE=$(subtract_days "$(TZ='America/New_York' date '+%Y-%m-%d')" 1)
   while ! is_workday "$CANDIDATE"; do
     CANDIDATE=$(subtract_days "$CANDIDATE" 1)
   done
   LOOKBACK_DATE="$CANDIDATE"
   # LOOKBACK_DATE is now the most recent prior workday (YYYY-MM-DD)
   ```

3. **Convert to an ISO 8601 timestamp** with the correct UTC offset (handles EST/EDT automatically):
   ```bash
   # If user gave explicit $ARGUMENTS, convert that time reference directly.
   # If using smart default, LOOKBACK_DATE is set above — use its noon:
   SINCE_ISO=$(TZ='America/New_York' date -d "${LOOKBACK_DATE} 12:00" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || TZ='America/New_York' date -jf '%Y-%m-%d %H:%M' "${LOOKBACK_DATE} 12:00" '+%Y-%m-%dT%H:%M:%S%z')
   SINCE_ISO=$(printf '%s' "$SINCE_ISO" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')
   ```
   If the user provided an explicit time reference via `$ARGUMENTS`, skip the smart lookback and convert their reference directly (same as before).

### Step 2: Pull issues, PRs, and line counts

For each repo, run:
```bash
# Closed issues since the cutoff
gh issue list --state closed --search "closed:>$SINCE_ISO" --json number,title,closedAt --limit 100

# Merged PRs since the cutoff
gh pr list --state merged --search "merged:>$SINCE_ISO" --json number,title,mergedAt,additions,deletions --limit 100

# Currently open PRs (in progress work)
gh pr list --state open --author @me --json number,title,createdAt,additions,deletions
```

### Step 3: Read PR bodies (CRITICAL — do not skip)

**This is what makes the report useful.** Titles alone cannot convey business context.

For every merged PR and every open PR (using the `number` field from Step 2's JSON output), read the PR body:
```bash
# For each PR number from Step 2:
gh pr view "$PR_NUMBER" --json body,title,additions,deletions
```

Scan each PR body for:
- **What the change enables** — the "so what" for the business
- **Concrete numbers** — record counts, accuracy metrics, coverage stats, thresholds
- **Which part of the system** this advances — classification, scraping, data pipeline, UI, etc.

If a PR body is thin or template-only, extract the linked issue number (look for `Fixes #N`, `Closes #N`, or similar patterns in the PR body) and read the issue body:
```bash
gh issue view "$ISSUE_NUMBER" --json body,title
```

### Step 4: Identify business themes

Group the PRs/issues into **2-5 business themes** based on what they collectively accomplish. A theme is a capability or milestone, not a file or module. Examples of good themes:
- "Carrier classification pipeline is production-ready"
- "Portal coverage map is now accurate and scrapable"
- "Batch scraping infrastructure is ready to execute"

Each theme should map to one section of the report.

## How to write the report

### Opening line
Lead with scale stats in a single line:
```text
Since [time reference]: [N] PRs merged, [K] open, ~[M] issues closed, ~[L] lines added / ~[D] removed (~[net] net)
```
- Lines = sum additions and deletions across merged PRs separately, then compute net

### Body: themed sections

For each business theme, write a short paragraph (2-5 sentences) that explains:
1. **What the system can now do** that it couldn't before (lead with this)
2. **Key concrete numbers** from the PR bodies — record counts, accuracy percentages, coverage stats, state counts, etc. These make the report credible and useful.
3. **How it fits** into the broader goal or next step

Name each theme with a bold one-liner that captures the business outcome, not the technical action. e.g., "**Carrier classification pipeline is production-ready**" not "**Added classification code**".

### Open PRs
Mention open PRs inline if they relate to a theme, or as a standalone line at the end:
```text
**Open PR:** #N (short description of what it does and why)
```

### Closing synthesis
End with a 1-2 sentence "net effect" that answers: "What can the system do now that it couldn't at the start of this period?" This is the single most important line — it's what a PM or exec would read if they read nothing else.

## Writing rules
- Frame everything in terms of **business value and system capabilities**, not file names or technical implementation
- **Include concrete numbers** from PR bodies — these are what make the report useful vs. generic. Counts, percentages, thresholds, coverage metrics.
- Group related issues/PRs into a single theme — never list PRs individually unless there are fewer than 4 total
- Write from the user's perspective ("I" / "we") for direct paste into standup
- No word limit — let the report be as long as it needs to be to convey meaningful context, but stay concise. Typical range: 150-400 words depending on volume of work.
- Do NOT mention CR review cycles, code review tooling, or process details — focus on outcomes
- Do NOT pad with filler or repeat the same point in different words
