<!-- pm-routing:begin -->
Route `resume:load`. Load config and persisted work for a resume. Continue to resume:fetch after the existing state checks.
<!-- pm-routing:end -->
### 1A.1: Load pm-config.md

<!-- test-anchor: pm-resume-load-config -->
```bash
pm_resume_config() (
  umask 077
  local source_config=.claude/pm-config.md config_snapshot
  local list_rc=0 section_rc=0 section_names section_name section_body config_body=""
  if [ -z "${PM_CONFIG_GET:-}" ]; then
    printf '%s\n' 'RESUME_CONFIG=defaults' 'LIST_RC=1'
    return
  fi
  if [ ! -e "$source_config" ] && [ ! -L "$source_config" ]; then
    printf '%s\n' 'RESUME_CONFIG=missing' 'LIST_RC=2'
    return
  fi
  if [ ! -f "$source_config" ] || ! config_snapshot=$(mktemp "${TMPDIR:-/tmp}/pm-resume-config.XXXXXX"); then
    printf '%s\n' 'RESUME_CONFIG=unreadable' 'LIST_RC=2'
    return
  fi
  trap 'rm -f "$config_snapshot"' EXIT
  # A copy that spans an in-place edit can contain more than one version.
  if ! cat "$source_config" > "$config_snapshot" || ! cmp -s "$source_config" "$config_snapshot"; then
    printf '%s\n' 'RESUME_CONFIG=unreadable' 'LIST_RC=2'
    return
  fi

  section_names=$("$PM_CONFIG_GET" --list --file "$config_snapshot" 2>/dev/null) || list_rc=$?
  if [ "$list_rc" -eq 0 ]; then
    while IFS= read -r section_name; do
      [ -n "$section_name" ] || continue
      section_rc=0
      section_body=$("$PM_CONFIG_GET" --section "$section_name" --file "$config_snapshot" 2>/dev/null) ||
        section_rc=$?
      case "$section_rc" in
        0|1) printf -v config_body '%s## %s\n%s\n' "$config_body" "$section_name" "$section_body" ;;
        *) list_rc="$section_rc"; break ;;
      esac
    done <<< "$section_names"
  fi
  case "$list_rc" in
    0) printf 'RESUME_CONFIG=ready\nLIST_RC=0\n%s' "$config_body" ;;
    1) printf '%s\n' 'RESUME_CONFIG=empty' 'LIST_RC=1' ;;
    *) printf 'RESUME_CONFIG=failed\nLIST_RC=%s\n' "$list_rc" ;;
  esac
)
pm_resume_config
```

Continue with defaults on `defaults` or with no section bodies on `empty`.
On `missing`, tell the user to run `/pm-handoff` to bootstrap the config
and finish this resume as config unavailable. On `unreadable` or `failed`,
report the read failure and stop before using any section. The list and
all section lookups use one private snapshot whose bytes matched a second read before parsing.

### 1A.2: Load in-flight state

```bash
# Session-wide orchestration state — SCOPED to the invoking repo (issue #687).
# --session-view projects the whole state file down to THIS repo's `.prs`,
# `.root_repo`, and the `.active_agents` map entries that belong here; another
# repo's PRs, and the agents attributable to them, never appear in the default
# view. Attribution is by `.owner_repo`, else `.pr`: an entry carrying NEITHER
# is unattributable, so the projection keeps it rather than guessing — treat
# such an entry as "possibly foreign", not as this repo's. Repo resolution reuses session-state.sh's
# precedence (--repo / $CLAUDE_SESSION_REPO / cwd origin, per #638). NEVER use
# `--get .` here — it dumps every repo's state and is the leak this scoping fixes.
SESSION_VIEW=$("$SESSION_STATE_SH" --session-view 2>/dev/null || echo "NO_SESSION_STATE")
echo "$SESSION_VIEW"

# Refill pause (issue #823) — read it EXPLICITLY. --session-view lifts only
# `.prs` and `.root_repo` out of the repo block and then deletes `.repos`, so a
# repo-scoped `refill` never appears in the projection above. Skipping this read
# is how a resumed thread silently resumes refilling after the user said stop.
REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null)
REFILL_RC=0
REFILL_PAUSED=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].refill.paused" 2>/dev/null) || REFILL_RC=$?
echo "REFILL_PAUSED=${REFILL_PAUSED:-null} REFILL_RC=$REFILL_RC"

# Day-mode posture (Step 2D) — read explicitly for exactly the same reason: it
# lives under the repo block, which --session-view deletes after lifting `.prs`
# and `.root_repo`, so it is invisible above. A resumed thread that skips this
# read cannot tell an armed day loop from a dead one, and reports neither.
# Keep the exit code: `|| echo null` here would render an unreadable state
# identical to "no day loop has ever run", and 1A.4 would then report nothing
# at all about a loop that may still be ticking.
DAY_RC=0
DAY_STATE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day") || DAY_RC=$?
echo "DAY_STATE=${DAY_STATE:-null} DAY_RC=$DAY_RC"

```

Run the handoff block in the same shell as the scoped state reads above.
Resolve handoffs from that scoped PR list. A scoped file takes precedence.
A flat or linked scoped file must name this repository. Read each payload once
and reject malformed or mismatched identities.

<!-- test-anchor: pm-resume-scoped-handoffs -->
```bash
SCOPED_PRS=""
CUR_REPO="${REPO_KEY:-}"
if [[ "$CUR_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ &&
      "/$CUR_REPO/" != */./* && "/$CUR_REPO/" != */../* ]]; then
  SCOPED_PRS=$(jq -sr --arg repo "$CUR_REPO" '
    select(length == 1) | .[0] | objects | select(.repo == $repo)
    | .prs | objects | keys[] | select(test("\\A[1-9][0-9]*\\z"))
  ' <<< "${SESSION_VIEW:-}" 2>/dev/null) || SCOPED_PRS=""
fi
handoff_root=""
if [[ "${HOME:-}" == /* ]]; then
  # Keep the original path so the physical comparison detects linked HOME too.
  handoff_root="${HOME%/}/.claude/handoffs"
fi
found_handoffs=false
while IFS= read -r n; do
  [[ -n "$handoff_root" && "$n" =~ ^[1-9][0-9]*$ ]] || continue
  scoped_dir="$handoff_root/$CUR_REPO"
  f="$scoped_dir/pr-$n-handoff.json"
  require_owner=false
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    f="$handoff_root/pr-$n-handoff.json"
    require_owner=true
  elif [ -L "$f" ] || ! physical_dir=$(cd -- "$scoped_dir" 2>/dev/null && pwd -P) ||
       [ "$physical_dir" != "$scoped_dir" ]; then
    require_owner=true
  fi
  [ -f "$f" ] && [ -r "$f" ] || continue
  payload=$(jq -cse --arg repo "$CUR_REPO" --arg pr "$n" --argjson require_owner "$require_owner" '
    select(length == 1) | .[0] | objects |
    select((has("pr_number") | not) or (.pr_number | type == "number" and tostring == $pr)) |
    select(
      if .owner_repo == null then ($require_owner | not)
      else (.owner_repo | type == "string" and ascii_downcase == ($repo | ascii_downcase))
      end)
    ' "$f" 2>/dev/null) || continue
  found_handoffs=true
  printf '%s\n%s\n' "--- $f ---" "$payload"
done <<< "$SCOPED_PRS"
$found_handoffs || echo NO_HANDOFF_FILES
```

> **Invoking-repo scope (issue #687).** Every default surface of `/pm` — the
> assignments table, rankings, suggestions, and offered actions — stays in the
> invoking repo's lane. The scoped read above is where that starts; the GitHub
> views (`gh pr/issue list`) are already cwd-repo-scoped by `gh`. **Cross-repo
> reporting is opt-in:** only when the user explicitly asks to see other repos'
> work, read `session-state.sh --session-view --all-repos` (or `--get .`) — and
> never *offer or perform* a write action (cleanup, merge, rebase, close)
> against a PR/issue outside the invoking repo.

Interpret both together, exactly as 3.4's table does: `REFILL_RC=0` with `true` means a human stopped refilling in an earlier turn — it stays paused, and 1A.4 says so in the recovered-state report. `REFILL_RC=0` with `false`/`null`, or `REFILL_RC=3` (no state file ever written), is the default — refill is on. **Any other `REFILL_RC` is unreadable state, not permission:** treat refill as paused and report it that way until the state file is readable again.

Parse any found state into an assignments table:

| PR | Issue | Phase | Reviewer | Last SHA | Notes |
|----|-------|-------|----------|----------|-------|

