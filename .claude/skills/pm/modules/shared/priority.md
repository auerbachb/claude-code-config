<!-- pm-routing:begin -->
Route `shared:priority`. Read the operator order after config on rank load, or at the existing Step 3.4 priority gate on refill.
<!-- pm-routing:end -->
### 1B.1a: Load the operator priority (`/desk`, issue #1767)

The operator can reorder the backlog from `/desk` (`top`, `bump`, `park`, `drop`). It lands in `.claude/pm-priority.json` at the repo's main checkout, next to `pm-config.md`, and `pm-priority.sh` is its only reader. The file is optional: absent means no override.

<!-- test-anchor: pm-1b1a-priority-read -->
```bash
PRIO_RC=0; PRIO_JSON=""
if [[ -n "$PM_PRIORITY_SH" ]]; then
  PRIO_JSON=$("$PM_PRIORITY_SH" show --json 2>/dev/null) || PRIO_RC=$?
else
  # Step 0's DEGRADED case: no helper, but the operator may still have written a
  # file at the main checkout's root. An order nothing here can read is unreadable.
  PRIO_GITDIR=$(git rev-parse --git-common-dir 2>/dev/null) || PRIO_GITDIR=""
  if [[ -n "$PRIO_GITDIR" ]] && PRIO_MAIN=$(cd "$PRIO_GITDIR/.." 2>/dev/null && pwd) \
     && [[ -e "$PRIO_MAIN/.claude/pm-priority.json" ]]; then
    PRIO_RC=127
  fi
fi
[[ "$PRIO_RC" -eq 0 && -n "$PRIO_JSON" ]] || PRIO_JSON='{"present":false,"order":[],"parked":[]}'
PRIORITY_UNREADABLE=false
case "$PRIO_RC" in
  0|3) ;;                          # read (absent = none), or no git checkout here: no override
  *)   PRIORITY_UNREADABLE=true ;;   # 4 = unreadable file; 127 = no helper but a file; anything else too
esac
```

`PRIORITY_STATUS` for the context line (`pm-output-templates.md`): `unreadable` when `PRIORITY_UNREADABLE=true` (a file the helper rejects, or Step 0's DEGRADED case with a file present); `none` when `.order` and `.parked` are both empty; otherwise `N ordered, M parked`. **Unreadable fails closed:** rank and report without the override, warn in one line (`Operator priority unreadable (<file>) — fix or remove it; no autonomous launches until then`), and launch nothing autonomously (1B.5's default dispatch, 3.4's refill) — parking is a "do not start" instruction, and an unreadable file may be hiding one. A request in chat naming issues still proceeds. Re-run this read wherever a ranking is rebuilt — a mid-session re-prioritize (3.3) and every refill (3.4, so every day-mode tick) — so a desk edit takes effect at the next one without restarting `/pm`.

