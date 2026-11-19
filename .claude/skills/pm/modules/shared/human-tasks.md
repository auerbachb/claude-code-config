<!-- pm-routing:begin -->
Route `shared:human-tasks`. Save every operator-only item this run surfaces, and count the repo's open human tasks for the report.
<!-- pm-routing:end -->
### Human tasks: save what only the operator can do, and count what is open (issue #2563)

`/pm` is a checkpoint for the human-task list (`.claude/reference/owner-tasks.md`): before it reports, everything it hands the operator is on the list, and the report says how many are open. The parent never reads the list itself (`.claude/reference/lean-orchestrator.md`): `pm-human-tasks.sh` reads, de-duplicates, saves and counts, and the parent prints the `LINE=` it returns.

**What counts as operator-only.** An item `/pm` surfaces that only the operator can do, after the capability ladder failed, with one reason from `owner-tasks.md` §Why a person (`sign-in`, `legal-agreement`, `payment-detail`, `secret-value`, `physical-device`, `judgment-call`):

- each `OWNER_ACTION:` line a worker's exit report carries (`exit-report-extract.sh` forwards them as `OWNER_ACTION=` lines);
- each owner-action blocker this run surfaces, and each row it puts under **Needs you** in a progress report.

A question recorded on the human queue (`D-<n>`, or `U-<n>` while unattended) is not a task: it waits on an answer, not on work. A decision the operator must make with nothing to do afterwards is a `judgment-call` task only when it blocks a pipeline.

**Save without asking, in every mode.** Saving is never a question: a cold start, a resume, a `/pm day` tick and an unattended run (presence away) all save the same way, with no menu and no `U-<n>` record. `--source` names the PR, else the issue, as a URL or `#N`. `--what` names the variable, account or page, never a value.

<!-- test-anchor: pm-human-tasks-save -->
```bash
# One call per item. Bind exactly one of PM_HT_ACTION (an OWNER_ACTION line)
# or PM_HT_WHAT + PM_HT_WHY ("<reason>: <free text>"), plus PM_HT_SOURCE.
PM_HT_LINE=''
if [[ -z "${PM_HUMAN_TASKS_SH:-}" ]]; then
  PM_HT_LINE='not saved to the human-task list: pm-human-tasks.sh not found (checked all three paths)'
elif [[ -n "${PM_HT_ACTION:-}" ]]; then
  PM_HT_OUT=$("$PM_HUMAN_TASKS_SH" save --owner-action "$PM_HT_ACTION" --source "$PM_HT_SOURCE") || true
  PM_HT_LINE=$(sed -n 's/^LINE=//p' <<< "${PM_HT_OUT:-}")
else
  PM_HT_OUT=$("$PM_HUMAN_TASKS_SH" save --what "$PM_HT_WHAT" --why "$PM_HT_WHY" --source "$PM_HT_SOURCE") || true
  PM_HT_LINE=$(sed -n 's/^LINE=//p' <<< "${PM_HT_OUT:-}")
fi
[[ -n "$PM_HT_LINE" ]] || PM_HT_LINE='not saved to the human-task list: pm-human-tasks.sh printed no result'
printf '%s\n' "$PM_HT_LINE"
unset PM_HT_ACTION PM_HT_WHAT PM_HT_WHY PM_HT_OUT   # the next item binds its own
```

Print each `LINE=` as is, beside the item in the report: `RESULT=saved` is the receipt (`human task ht-… saved: … (<reason>)`), `RESULT=skipped` says it is already on the list (same what and source, done ones included), `RESULT=not_saved` names why it was not saved (exit 3: this repo is public and no private bucket is set), and `RESULT=unconfirmed` means a write may have landed but could not be checked, so it is never saved again blindly. The item itself is still stated in chat whatever the result; a failed save never stops ranking, dispatch or monitoring.

**Count before the report.** Run once per report: the cold-start presentation (1B.5), the resume presentation (1A.4) and a due progress report (3.3a). Print `PM_HT_COUNT_LINE` as one line in that report, after any saves this turn so the count includes them.

<!-- test-anchor: pm-human-tasks-count -->
```bash
if [[ -n "${PM_HUMAN_TASKS_SH:-}" ]]; then
  PM_HT_COUNT_OUT=$("$PM_HUMAN_TASKS_SH" count) || true
  PM_HT_COUNT_LINE=$(sed -n 's/^LINE=//p' <<< "${PM_HT_COUNT_OUT:-}")
else
  PM_HT_COUNT_LINE='Human tasks: count unknown (pm-human-tasks.sh not found)'
fi
[[ -n "$PM_HT_COUNT_LINE" ]] || PM_HT_COUNT_LINE='Human tasks: count unknown (pm-human-tasks.sh printed no result)'
printf '%s\n' "$PM_HT_COUNT_LINE"
```

`HUMAN_TASKS=<N>` prints `Human tasks: N open for this repo`. An unreadable list prints `Human tasks: list unreadable … — count unknown, not zero`: never report an unreadable or missing list as zero open tasks.
